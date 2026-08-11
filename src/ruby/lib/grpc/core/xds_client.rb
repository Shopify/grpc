# frozen_string_literal: true

# Copyright 2026 gRPC authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require_relative 'reconnect_backoff'
require_relative 'rpc_stream'
require_relative 'xds_bootstrap'

# The generated message classes live under src/ruby/pb/xds (see
# generate_xds_pb.sh) rather than src/ruby/pb, because their own `require`
# by the test .proto fixtures would risk a name collision. Prepending this
# directory to the load path is the whole integration cost.
XDS_PB_DIR = File.expand_path('../../../pb/xds', __dir__)
$LOAD_PATH.unshift(XDS_PB_DIR) unless $LOAD_PATH.include?(XDS_PB_DIR)

require 'envoy/config/cluster/v3/cluster_pb'
require 'envoy/config/core/v3/base_pb'
require 'envoy/config/endpoint/v3/endpoint_pb'
require 'envoy/config/endpoint/v3/endpoint_components_pb'
require 'envoy/config/listener/v3/listener_pb'
require 'envoy/config/listener/v3/api_listener_pb'
require 'envoy/config/route/v3/route_pb'
require 'envoy/config/route/v3/route_components_pb'
require 'envoy/extensions/filters/network/http_connection_manager/v3/http_connection_manager_pb'
require 'envoy/service/discovery/v3/discovery_pb'
require 'google/protobuf/any_pb'
require 'google/protobuf/struct_pb'
require 'google/rpc/status_pb'

module GRPC
  module Core
    # A client for the Aggregated Discovery Service (ADS): one bidi stream to
    # the bootstrap's management server, carrying LDS/RDS/CDS/EDS for every
    # xds:// channel in the process. There is exactly one instance per
    # process (see .instance) because there is exactly one bootstrap
    # (GRPC_XDS_BOOTSTRAP is a process-wide environment variable) --
    # concurrent xds:// channels for different resource names share the one
    # ADS stream rather than opening one apiece.
    #
    # Out of scope: LRS load reporting, SDS/mTLS certificate provisioning,
    # RBAC and fault-injection filters, aggregate clusters, xDS federation
    # (authority-qualified xds:// targets), a secondary management server on
    # xds_servers[1..], and weighted-locality routing beyond flattening every
    # healthy endpoint a cluster's localities name.
    #
    # @api private
    class XdsClient
      Error = Class.new(StandardError)

      TYPE_LISTENER = 'type.googleapis.com/envoy.config.listener.v3.Listener'
      TYPE_ROUTE = 'type.googleapis.com/envoy.config.route.v3.RouteConfiguration'
      TYPE_CLUSTER = 'type.googleapis.com/envoy.config.cluster.v3.Cluster'
      TYPE_ENDPOINT = 'type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment'

      RESOURCE_CLASSES = {
        TYPE_LISTENER => Envoy::Config::Listener::V3::Listener,
        TYPE_ROUTE => Envoy::Config::Route::V3::RouteConfiguration,
        TYPE_CLUSTER => Envoy::Config::Cluster::V3::Cluster,
        TYPE_ENDPOINT => Envoy::Config::Endpoint::V3::ClusterLoadAssignment
      }.freeze

      ADS_METHOD = '/envoy.service.discovery.v3.AggregatedDiscoveryService/StreamAggregatedResources'

      # A cluster's endpoints are unusable in these health states; see
      # envoy/config/core/v3/health_check.proto's HealthStatus. UNKNOWN (0)
      # and HEALTHY (1) pass, DEGRADED (5) passes too since dropping it
      # entirely would be worse than an eds-only client without full
      # weighted-priority support picking a degraded endpoint.
      UNUSABLE_HEALTH_STATUSES = [2, 3, 4].freeze # UNHEALTHY, DRAINING, TIMEOUT

      INITIAL_BACKOFF = 1
      MAX_BACKOFF = 120
      DEFAULT_RESOLVE_TIMEOUT = 10
      # How long an idle connection (nothing new to subscribe, nothing
      # ACK/NACK-worthy pending) waits before resending one already-current
      # subscription, purely so a dead management server is discovered in
      # bounded time instead of only on the next real change. See
      # #keepalive_request_locked.
      KEEPALIVE_INTERVAL = 3
      QUEUE_POLL_INTERVAL = 0.1

      class << self
        # Parses (and caches) the bootstrap. Called from
        # Transport.parse_target so a bad GRPC_XDS_BOOTSTRAP fails channel
        # construction instead of the first RPC.
        def bootstrap!
          @bootstrap_mu.synchronize { @bootstrap ||= XdsBootstrap.load }
        end

        # The one XdsClient for this process, built (and its ADS stream
        # started) lazily on first resolve.
        def instance
          @instance_mu.synchronize { @instance ||= new(bootstrap!) }
        end

        # @api private -- specs only, so a bad bootstrap in one example
        # cannot leak a memoized client (or its background thread) into the
        # next.
        def reset_for_testing!
          client = @instance_mu.synchronize do
            client = @instance
            @instance = nil
            client
          end
          client&.close
          @bootstrap_mu.synchronize { @bootstrap = nil }
        end
      end
      @bootstrap_mu = Mutex.new
      @instance_mu = Mutex.new

      def initialize(config)
        server = config.servers.first
        fail XdsBootstrap::Error, 'the xDS bootstrap config has no usable xds_servers entry' if server.nil?
        @server_uri = server.server_uri
        @channel_creds = channel_creds_for(server.channel_creds_type)
        @node = build_node(config.node)
        @listener_template = config.listener_resource_name_template

        @mu = Mutex.new
        @cv = ConditionVariable.new
        @closed = false

        # Per resource type (a TYPE_* constant): the resource names this
        # client has subscribed to, the last version_info ACKed (persists
        # across a reconnect), and the last nonce seen on the current stream
        # (reset to '' on every reconnect).
        @subscribed = Hash.new { |h, k| h[k] = {} }
        @versions = Hash.new('')
        @nonces = Hash.new('')
        # Per resource type: name => decoded message last accepted.
        @resources = Hash.new { |h, k| h[k] = {} }

        # The chain a listener name resolves through, filled in as each
        # link's response arrives.
        @listener_route_config = {} # listener name => route config name
        @route_cluster = {} # route config name => cluster name
        @cluster_eds_name = {} # cluster name => EDS service_name

        @request_queue = nil
        @backoff = ReconnectBackoff.new(initial: INITIAL_BACKOFF, min: INITIAL_BACKOFF, max: MAX_BACKOFF)
        @stream_thread = Thread.new do
          Thread.current.name = 'xds-ads'
          drive_stream
        end
      end

      # Subscribes (if not already) to +listener_name+ and blocks until its
      # LDS -> RDS -> CDS -> EDS chain has resolved to a set of endpoints, or
      # +timeout+ seconds pass.
      #
      # @return [Array<Transport::Target>]
      def resolve_endpoints(listener_name, timeout: DEFAULT_RESOLVE_TIMEOUT)
        subscribe(TYPE_LISTENER, resolved_listener_name(listener_name))
        deadline = RpcStream.now + timeout
        @mu.synchronize do
          loop do
            addresses = endpoints_for_locked(resolved_listener_name(listener_name))
            return addresses unless addresses.nil?
            remaining = deadline - RpcStream.now
            if remaining <= 0
              fail Error, "xDS resolution of #{listener_name.inspect} via #{@server_uri} timed out"
            end
            @cv.wait(@mu, [remaining, 0.05].min)
          end
        end
      end

      def close
        thread = @mu.synchronize do
          return if @closed
          @closed = true
          @cv.broadcast
          @request_queue&.push(:stop)
          @stream_thread
        end
        thread.wakeup if thread.alive?
        thread.join(5)
        nil
      end

      private

      # client_default_listener_resource_name_template substitutes "%s" for
      # the resource name a plain "xds:///name" target supplies; absent a
      # template (the common case), the name is used as-is.
      def resolved_listener_name(name)
        return name if @listener_template.nil? || @listener_template.empty?
        @listener_template.sub('%s', name)
      end

      # ---- Wire-format channel creds for the management-server channel.
      # SDS-provisioned mTLS to the management server itself is out of
      # scope; "insecure" is honoured exactly, anything else falls back to
      # a plain TLS ChannelCredentials using the system trust store.
      def channel_creds_for(type)
        type == 'insecure' ? :this_channel_is_insecure : ChannelCredentials.new
      end

      def build_node(node_hash)
        Envoy::Config::Core::V3::Node.new(
          id: node_hash['id'].to_s,
          cluster: node_hash['cluster'].to_s,
          metadata: json_to_struct(node_hash['metadata'] || {})
        )
      end

      def json_to_struct(hash)
        s = Google::Protobuf::Struct.new
        hash.each { |k, v| s.fields[k.to_s] = json_to_value(v) }
        s
      end

      def json_to_value(value)
        case value
        when nil then Google::Protobuf::Value.new(null_value: :NULL_VALUE)
        when true, false then Google::Protobuf::Value.new(bool_value: value)
        when Numeric then Google::Protobuf::Value.new(number_value: value.to_f)
        when Hash then Google::Protobuf::Value.new(struct_value: json_to_struct(value))
        when Array
          list = Google::Protobuf::ListValue.new(values: v.map { |e| json_to_value(e) })
          Google::Protobuf::Value.new(list_value: list)
        else Google::Protobuf::Value.new(string_value: v.to_s)
        end
      end

      # ---- Subscription bookkeeping and request sending.

      def subscribe(type_url, name)
        @mu.synchronize do
          next if @subscribed[type_url].key?(name)
          @subscribed[type_url][name] = true
          send_request_locked(type_url)
        end
      end

      def build_request_locked(type_url, error_detail: nil)
        request = Envoy::Service::Discovery::V3::DiscoveryRequest.new(
          version_info: @versions[type_url],
          node: @node,
          resource_names: @subscribed[type_url].keys,
          type_url: type_url,
          response_nonce: @nonces[type_url]
        )
        request.error_detail = error_detail unless error_detail.nil?
        request
      end

      def send_request_locked(type_url, error_detail: nil)
        return if @request_queue.nil?
        @request_queue.push(build_request_locked(type_url, error_detail: error_detail))
      end

      # A response the client already ACKed carries nothing new to send, so
      # an idle steady-state connection can go indefinitely long between
      # writes. That is invisible to the *peer* half of the connection --
      # bidi_call's write loop only discovers the stream has died the next
      # time it actually attempts to send -- so an idle connection whose
      # management server vanishes would otherwise never be noticed, and
      # #close's join on the stream thread would hang forever waiting for a
      # response that is never coming. Resending one already-subscribed
      # type's current state is a harmless no-op to a well-behaved server
      # and, to a dead one, the write that finally raises.
      def keepalive_request_locked
        type_url = RESOURCE_CLASSES.each_key.find { |t| !@subscribed[t].empty? }
        return nil if type_url.nil?
        build_request_locked(type_url)
      end

      # ---- Response processing: decode, ACK or NACK, follow the chain.

      class DecodeError < StandardError; end

      def handle_response(response)
        type_url = response.type_url
        decoded = decode_resources(type_url, response.resources)
        @mu.synchronize do
          @nonces[type_url] = response.nonce
          apply_locked(type_url, decoded)
          @versions[type_url] = response.version_info
          send_request_locked(type_url)
          @cv.broadcast
        end
      rescue DecodeError => e
        @mu.synchronize do
          @nonces[type_url] = response.nonce
          status = Google::Rpc::Status.new(code: StatusCodes::INVALID_ARGUMENT, message: e.message)
          send_request_locked(type_url, error_detail: status)
        end
      end

      def decode_resources(type_url, anys)
        klass = RESOURCE_CLASSES.fetch(type_url) { fail DecodeError, "unsupported resource type #{type_url}" }
        anys.to_h do |any|
          msg = klass.decode(any.value)
          [type_url == TYPE_ENDPOINT ? msg.cluster_name : msg.name, msg]
        end
      rescue Google::Protobuf::ParseError => e
        raise DecodeError, "malformed #{type_url} resource: #{e.message}"
      end

      # Stores the newly accepted resources and, still under @mu, subscribes
      # to whatever the next link in the chain names.
      def apply_locked(type_url, decoded)
        @resources[type_url].merge!(decoded)
        case type_url
        when TYPE_LISTENER then decoded.each_value { |l| follow_listener_locked(l) }
        when TYPE_ROUTE then decoded.each_key { |name| follow_route_locked(name) }
        when TYPE_CLUSTER then decoded.each_value { |c| follow_cluster_locked(c) }
        end
      end

      def follow_listener_locked(listener)
        route_config_name = route_config_name_of(listener)
        return if route_config_name.nil?
        @listener_route_config[listener.name] = route_config_name
        return if @subscribed[TYPE_ROUTE].key?(route_config_name)
        @subscribed[TYPE_ROUTE][route_config_name] = true
        send_request_locked(TYPE_ROUTE)
      end

      # A Listener's ApiListener wraps an HttpConnectionManager as an Any;
      # this reaches into it for the RDS route_config_name, the only piece
      # this client needs. An inline route_config (no RDS indirection) is
      # decoded straight into @resources[TYPE_ROUTE] under its own name so
      # the RDS-following logic below needs no special case for it.
      def route_config_name_of(listener)
        any = listener.api_listener&.api_listener
        return nil if any.nil?
        hcm = Envoy::Extensions::Filters::Network::HttpConnectionManager::V3::HttpConnectionManager.decode(any.value)
        case hcm.route_specifier
        when :rds then hcm.rds.route_config_name
        when :route_config
          @resources[TYPE_ROUTE][hcm.route_config.name] = hcm.route_config
          hcm.route_config.name
        end
      rescue Google::Protobuf::ParseError
        nil
      end

      def follow_route_locked(route_config_name)
        route = @resources[TYPE_ROUTE][route_config_name]
        cluster_name = cluster_name_of(route)
        return if cluster_name.nil?
        @route_cluster[route_config_name] = cluster_name
        return if @subscribed[TYPE_CLUSTER].key?(cluster_name)
        @subscribed[TYPE_CLUSTER][cluster_name] = true
        send_request_locked(TYPE_CLUSTER)
      end

      # Picks the first route of the first plausibly-matching virtual host.
      # Full domain and path/header matching, and weighted-cluster splits
      # beyond "use the heaviest", are beyond what an EDS-endpoints-only
      # client needs.
      def cluster_name_of(route_config)
        return nil if route_config.nil?
        vhost = route_config.virtual_hosts.first
        return nil if vhost.nil?
        route = vhost.routes.find { |r| r.action == :route }
        route.nil? ? nil : cluster_of_action(route.route)
      end

      # A route names either one cluster or a weighted set. With no weighted
      # routing here, the heaviest is the only sensible reading of the set.
      def cluster_of_action(action)
        return action.cluster unless action.cluster.empty?
        action.weighted_clusters&.clusters&.max_by(&:weight)&.name
      end

      def follow_cluster_locked(cluster)
        eds_name = cluster.eds_cluster_config&.service_name
        eds_name = cluster.name if eds_name.nil? || eds_name.empty?
        @cluster_eds_name[cluster.name] = eds_name
        return if @subscribed[TYPE_ENDPOINT].key?(eds_name)
        @subscribed[TYPE_ENDPOINT][eds_name] = true
        send_request_locked(TYPE_ENDPOINT)
      end

      # Walks listener -> route config -> cluster -> endpoints. nil at any
      # link means "still waiting", not "failed" -- #resolve_endpoints
      # times that out rather than raising early, since the next response
      # may complete the chain.
      def endpoints_for_locked(listener_name)
        listener = @resources[TYPE_LISTENER][listener_name]
        return nil if listener.nil?
        route_config_name = @listener_route_config[listener_name]
        return nil if route_config_name.nil?
        cluster_name = @route_cluster[route_config_name]
        return nil if cluster_name.nil?
        eds_name = @cluster_eds_name[cluster_name]
        return nil if eds_name.nil?
        cla = @resources[TYPE_ENDPOINT][eds_name]
        return nil if cla.nil?
        endpoints_of(cla)
      end

      def endpoints_of(cla)
        cla.endpoints.flat_map do |locality|
          locality.lb_endpoints
                  .reject { |lbe| UNUSABLE_HEALTH_STATUSES.include?(lbe.health_status) }
                  .filter_map { |lbe| target_of(lbe) }
        end
      end

      def target_of(lb_endpoint)
        socket_address = lb_endpoint.endpoint&.address&.socket_address
        return nil if socket_address.nil?
        Transport::Target.new(:tcp, socket_address.address, socket_address.port_value, nil)
      end

      # ---- The ADS stream itself: connect, drive request/response, and on
      # any failure back off and reconnect, resending every subscription
      # this client has accumulated (with an empty nonce -- nonces do not
      # survive a stream -- but the last accepted version_info, which does).

      def drive_stream
        until @mu.synchronize { @closed }
          begin
            run_stream_once
            @backoff.reset
          rescue StandardError => e
            GRPC.logger.debug("xDS ADS stream to #{@server_uri} failed: #{e.class}: #{e.message}")
          end
          break if @mu.synchronize { @closed }
          sleep(@backoff.next_delay)
        end
      end

      def run_stream_once
        require_relative '../generic/client_stub'
        queue = Queue.new
        @mu.synchronize do
          @nonces.clear
          @request_queue = queue
          RESOURCE_CLASSES.each_key { |type_url| send_request_locked(type_url) unless @subscribed[type_url].empty? }
        end
        stub = GRPC::ClientStub.new(@server_uri, @channel_creds)
        requests = Enumerator.new { |y| pump_requests(queue, y) }
        marshal = ->(msg) { msg.class.encode(msg) }
        unmarshal = ->(bytes) { Envoy::Service::Discovery::V3::DiscoveryResponse.decode(bytes) }
        responses = stub.bidi_streamer(ADS_METHOD, requests, marshal, unmarshal)
        responses.each { |response| handle_response(response) }
      ensure
        @mu.synchronize { @request_queue = nil if @request_queue.equal?(queue) }
      end

      # Feeds +y+ from +queue+, polling rather than blocking indefinitely on
      # an empty queue: see #keepalive_request_locked for why an idle
      # connection still needs to occasionally attempt a write.
      def pump_requests(queue, yielder)
        idle_since = RpcStream.now
        loop do
          req = queue.pop(true)
          break if req == :stop
          yielder << req
          idle_since = RpcStream.now
        rescue ThreadError
          if RpcStream.now - idle_since >= KEEPALIVE_INTERVAL
            keepalive = @mu.synchronize { keepalive_request_locked }
            idle_since = RpcStream.now
            yielder << keepalive unless keepalive.nil?
          else
            sleep(QUEUE_POLL_INTERVAL)
          end
        end
      end
    end
  end
end
