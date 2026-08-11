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

module GRPC
  module Core
    class XdsClient
      # One management server's ADS bidi stream (LDS/RDS/CDS/EDS), plus --
      # lazily, only if some Cluster it hears about actually asks for it --
      # that same server's LRS stream. XdsClient owns one of these per
      # distinct server_uri (see XdsClient#connection_for); a process with
      # only the default, unfederated bootstrap has exactly one.
      #
      # @api private
      class AdsConnection
        TYPE_LISTENER = XdsClient::TYPE_LISTENER
        TYPE_ROUTE = XdsClient::TYPE_ROUTE
        TYPE_CLUSTER = XdsClient::TYPE_CLUSTER
        TYPE_ENDPOINT = XdsClient::TYPE_ENDPOINT

        RESOURCE_CLASSES = {
          TYPE_LISTENER => Envoy::Config::Listener::V3::Listener,
          TYPE_ROUTE => Envoy::Config::Route::V3::RouteConfiguration,
          TYPE_CLUSTER => Envoy::Config::Cluster::V3::Cluster,
          TYPE_ENDPOINT => Envoy::Config::Endpoint::V3::ClusterLoadAssignment
        }.freeze

        ADS_METHOD = '/envoy.service.discovery.v3.AggregatedDiscoveryService/StreamAggregatedResources'
        LRS_METHOD = '/envoy.service.load_stats.v3.LoadReportingService/StreamLoadStats'

        # A cluster's endpoints are unusable in these health states; see
        # envoy/config/core/v3/health_check.proto's HealthStatus. UNKNOWN
        # (0) and HEALTHY (1) pass, DEGRADED (5) passes too since dropping
        # it entirely would be worse than an eds-only client without full
        # weighted-priority support picking a degraded endpoint.
        UNUSABLE_HEALTH_STATUSES = [2, 3, 4].freeze # UNHEALTHY, DRAINING, TIMEOUT

        INITIAL_BACKOFF = 1
        MAX_BACKOFF = 120
        # How long an idle connection (nothing new to subscribe/report,
        # nothing ACK/NACK-worthy pending) waits before resending one
        # already-current subscription (ADS) or checking whether an LRS
        # report is due (LRS), purely so a dead management server is
        # discovered in bounded time instead of only on the next real
        # change. See #keepalive_request_locked and #pump_lrs_requests.
        KEEPALIVE_INTERVAL = 3
        QUEUE_POLL_INTERVAL = 0.1

        def initialize(server, node)
          @server_uri = server.server_uri
          @channel_creds = channel_creds_for(server.channel_creds_type)
          @node = node

          @mu = Mutex.new
          @cv = ConditionVariable.new
          @closed = false

          # Per resource type (a TYPE_* constant): the resource names this
          # connection has subscribed to, the last version_info ACKed
          # (persists across a reconnect), and the last nonce seen on the
          # current stream (reset to '' on every reconnect).
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

          # LRS: clusters this connection has seen a Cluster#lrs_server
          # pointing at "self" for, their running counters (created lazily,
          # kept across reports so a cluster with no traffic yet still
          # gets a zeroed entry rather than crashing a Hash#fetch), and the
          # server's most recently stated interval/cluster list -- nil
          # until the first LoadStatsResponse arrives, at which point
          # #pump_lrs_requests starts actually reporting.
          @lrs_clusters = {}
          @lrs_counters = Hash.new { |h, k| h[k] = LrsCallCounter.new }
          @lrs_interval = nil
          @lrs_report_clusters = []
          @lrs_thread = nil
          @lrs_request_queue = nil
          @lrs_backoff = ReconnectBackoff.new(initial: INITIAL_BACKOFF, min: INITIAL_BACKOFF, max: MAX_BACKOFF)

          @request_queue = nil
          @backoff = ReconnectBackoff.new(initial: INITIAL_BACKOFF, min: INITIAL_BACKOFF, max: MAX_BACKOFF)
          @stream_thread = Thread.new do
            Thread.current.name = 'xds-ads'
            drive_stream
          end
        end

        # Subscribes (if not already) to +listener_name+ and blocks until
        # its LDS -> RDS -> CDS -> EDS chain has resolved to a set of
        # endpoints, or +timeout+ seconds pass.
        #
        # @return [Array<Transport::Target>]
        def resolve_endpoints(listener_name, timeout:)
          subscribe(TYPE_LISTENER, listener_name)
          deadline = RpcStream.now + timeout
          @mu.synchronize do
            loop do
              addresses = endpoints_for_locked(listener_name)
              return addresses unless addresses.nil?
              remaining = deadline - RpcStream.now
              if remaining <= 0
                fail XdsClient::Error, "xDS resolution of #{listener_name.inspect} via #{@server_uri} timed out"
              end
              @cv.wait(@mu, [remaining, 0.05].min)
            end
          end
        end

        def close
          ads_thread, lrs_thread = @mu.synchronize do
            return if @closed
            @closed = true
            @cv.broadcast
            @request_queue&.push(:stop)
            @lrs_request_queue&.push(:stop)
            [@stream_thread, @lrs_thread]
          end
          ads_thread.wakeup if ads_thread.alive?
          ads_thread.join(5)
          if lrs_thread
            lrs_thread.wakeup if lrs_thread.alive?
            lrs_thread.join(5)
          end
          nil
        end

        private

        # ---- Wire-format channel creds for the management-server channel.
        # SDS-provisioned mTLS to the management server itself is out of
        # scope; "insecure" is honoured exactly, anything else falls back
        # to a plain TLS ChannelCredentials using the system trust store.
        def channel_creds_for(type)
          type == 'insecure' ? :this_channel_is_insecure : ChannelCredentials.new
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

        # A response the client already ACKed carries nothing new to send,
        # so an idle steady-state connection can go indefinitely long
        # between writes. That is invisible to the *peer* half of the
        # connection -- bidi_call's write loop only discovers the stream
        # has died the next time it actually attempts to send -- so an
        # idle connection whose management server vanishes would otherwise
        # never be noticed, and #close's join on the stream thread would
        # hang forever waiting for a response that is never coming.
        # Resending one already-subscribed type's current state is a
        # harmless no-op to a well-behaved server and, to a dead one, the
        # write that finally raises.
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

        # Stores the newly accepted resources and, still under @mu,
        # subscribes to whatever the next link in the chain names.
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

        # A Listener's ApiListener wraps an HttpConnectionManager as an
        # Any; this reaches into it for the RDS route_config_name, the
        # only piece this client needs. An inline route_config (no RDS
        # indirection) is decoded straight into @resources[TYPE_ROUTE]
        # under its own name so the RDS-following logic below needs no
        # special case for it.
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

        # Picks the first route of the first plausibly-matching virtual
        # host. Full domain and path/header matching, and weighted-cluster
        # splits beyond "use the heaviest", are beyond what an
        # EDS-endpoints-only client needs.
        def cluster_name_of(route_config)
          return nil if route_config.nil?
          vhost = route_config.virtual_hosts.first
          return nil if vhost.nil?
          route = vhost.routes.find { |r| r.action == :route }
          route.nil? ? nil : cluster_of_action(route.route)
        end

        # A route names either one cluster or a weighted set. With no
        # weighted routing here, the heaviest is the only sensible reading
        # of the set.
        def cluster_of_action(action)
          return action.cluster unless action.cluster.empty?
          action.weighted_clusters&.clusters&.max_by(&:weight)&.name
        end

        def follow_cluster_locked(cluster)
          eds_name = cluster.eds_cluster_config&.service_name
          eds_name = cluster.name if eds_name.nil? || eds_name.empty?
          @cluster_eds_name[cluster.name] = eds_name
          note_lrs_locked(cluster)
          return if @subscribed[TYPE_ENDPOINT].key?(eds_name)
          @subscribed[TYPE_ENDPOINT][eds_name] = true
          send_request_locked(TYPE_ENDPOINT)
        end

        # Walks listener -> route config -> cluster -> endpoints. nil at
        # any link means "still waiting", not "failed" --
        # #resolve_endpoints times that out rather than raising early,
        # since the next response may complete the chain.
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
          endpoints_of(cla, cluster_name)
        end

        def endpoints_of(cla, cluster_name)
          counter = lrs_counter_for_locked(cluster_name)
          cla.endpoints.flat_map do |locality|
            locality.lb_endpoints
                    .reject { |lbe| UNUSABLE_HEALTH_STATUSES.include?(lbe.health_status) }
                    .filter_map { |lbe| target_of(lbe, counter) }
          end
        end

        def target_of(lb_endpoint, lrs_counter)
          socket_address = lb_endpoint.endpoint&.address&.socket_address
          return nil if socket_address.nil?
          Transport::Target.new(:tcp, socket_address.address, socket_address.port_value, nil, nil,
                                lb_endpoint.load_balancing_weight&.value, nil, lrs_counter)
        end

        # ---- The ADS stream itself: connect, drive request/response, and
        # on any failure back off and reconnect, resending every
        # subscription this connection has accumulated (with an empty
        # nonce -- nonces do not survive a stream -- but the last accepted
        # version_info, which does).

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
          # A fresh Channel per attempt, since the reconnect backoff picks
          # up where a dropped stream left off. Leaving it open past this
          # attempt would leak its connection-maintenance thread on every
          # reconnect.
          stub = GRPC::ClientStub.new(@server_uri, @channel_creds)
          begin
            requests = Enumerator.new { |y| pump_requests(queue, y) }
            marshal = ->(msg) { msg.class.encode(msg) }
            unmarshal = ->(bytes) { Envoy::Service::Discovery::V3::DiscoveryResponse.decode(bytes) }
            responses = stub.bidi_streamer(ADS_METHOD, requests, marshal, unmarshal)
            responses.each { |response| handle_response(response) }
          ensure
            # #close's own :stop only reaches whichever attempt's queue is
            # still @request_queue; a stream that ends on its own (an
            # error, or the peer closing) needs *this* attempt's queue
            # told to stop too, or the write thread bidi_streamer started
            # for it keeps polling an orphaned queue forever -- one leaked
            # thread per reconnect, for as long as the process runs.
            queue.push(:stop)
            stub.close
          end
        ensure
          @mu.synchronize { @request_queue = nil if @request_queue.equal?(queue) }
        end

        # Feeds +y+ from +queue+, polling rather than blocking indefinitely
        # on an empty queue: see #keepalive_request_locked for why an idle
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

        # ---- LRS: opened lazily, the first time a Cluster's lrs_server
        # names this same management server ("self"), and driven with its
        # own reconnect loop exactly like the ADS stream above.

        def note_lrs_locked(cluster)
          return unless cluster.lrs_server&.config_source_specifier == :self
          return if @lrs_clusters.key?(cluster.name)
          @lrs_clusters[cluster.name] = true
          ensure_lrs_stream_locked
        end

        def ensure_lrs_stream_locked
          return unless @lrs_thread.nil?
          @lrs_thread = Thread.new do
            Thread.current.name = 'xds-lrs'
            drive_lrs_stream
          end
        end

        # nil (LRS never requested by any cluster on this connection) or
        # not yet requested for +cluster_name+ specifically: no counter,
        # so the resolved Target carries none and Subchannel/Connection
        # never wire up anything for it.
        def lrs_counter_for_locked(cluster_name)
          return nil unless @lrs_clusters.key?(cluster_name)
          @lrs_counters[cluster_name]
        end

        def drive_lrs_stream
          until @mu.synchronize { @closed }
            begin
              run_lrs_stream_once
              @lrs_backoff.reset
            rescue StandardError => e
              GRPC.logger.debug("xDS LRS stream to #{@server_uri} failed: #{e.class}: #{e.message}")
            end
            break if @mu.synchronize { @closed }
            # A fresh stream restarts the handshake from scratch: the
            # server tells it which clusters and interval to report at
            # all over again, so a dropped LRS stream must not go on
            # reporting against a config that stream never actually saw.
            @mu.synchronize { @lrs_interval = nil }
            sleep(@lrs_backoff.next_delay)
          end
        end

        def run_lrs_stream_once
          require_relative '../generic/client_stub'
          queue = Queue.new
          @mu.synchronize { @lrs_request_queue = queue }
          stub = GRPC::ClientStub.new(@server_uri, @channel_creds)
          begin
            queue.push(Envoy::Service::LoadStats::V3::LoadStatsRequest.new(node: @node))
            requests = Enumerator.new { |y| pump_lrs_requests(queue, y) }
            marshal = ->(msg) { msg.class.encode(msg) }
            unmarshal = ->(bytes) { Envoy::Service::LoadStats::V3::LoadStatsResponse.decode(bytes) }
            responses = stub.bidi_streamer(LRS_METHOD, requests, marshal, unmarshal)
            responses.each { |response| handle_lrs_response(response) }
          ensure
            queue.push(:stop)
            stub.close
          end
        ensure
          @mu.synchronize { @lrs_request_queue = nil if @lrs_request_queue.equal?(queue) }
        end

        # The server names which clusters it wants reports for (a subset
        # of the ones this connection told it about via the initial,
        # stats-less request) and how often; #pump_lrs_requests starts
        # actually sending reports once @lrs_interval is set.
        def handle_lrs_response(response)
          @mu.synchronize do
            interval = response.load_reporting_interval
            @lrs_interval = interval.seconds.to_f + (interval.nanos / 1_000_000_000.0) unless interval.nil?
            @lrs_report_clusters = response.clusters.to_a
          end
        end

        # Mirrors #pump_requests: drains +queue+ (the initial
        # identification, here), and once @lrs_interval is known, sends a
        # fresh report every time that many seconds pass with nothing else
        # to send.
        def pump_lrs_requests(queue, yielder)
          last_report = RpcStream.now
          loop do
            req = queue.pop(true)
            break if req == :stop
            yielder << req
            last_report = RpcStream.now
          rescue ThreadError
            interval = @mu.synchronize { @lrs_interval }
            if interval && RpcStream.now - last_report >= interval
              yielder << build_lrs_report_locked
              last_report = RpcStream.now
            else
              sleep(QUEUE_POLL_INTERVAL)
            end
          end
        end

        def build_lrs_report_locked
          @mu.synchronize do
            cluster_stats = @lrs_report_clusters.map { |name| cluster_stats_for_locked(name) }
            Envoy::Service::LoadStats::V3::LoadStatsRequest.new(node: @node, cluster_stats: cluster_stats)
          end
        end

        def cluster_stats_for_locked(name)
          issued, success, failure, in_progress = @lrs_counters[name].snapshot!
          Envoy::Config::Endpoint::V3::ClusterStats.new(
            cluster_name: name,
            upstream_locality_stats: [
              Envoy::Config::Endpoint::V3::UpstreamLocalityStats.new(
                total_issued_requests: issued,
                total_successful_requests: success,
                total_error_requests: failure,
                total_requests_in_progress: in_progress
              )
            ]
          )
        end
      end
    end
  end
end
