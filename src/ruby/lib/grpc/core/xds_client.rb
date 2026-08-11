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
require 'envoy/config/endpoint/v3/load_report_pb'
require 'envoy/config/listener/v3/listener_pb'
require 'envoy/config/listener/v3/api_listener_pb'
require 'envoy/config/route/v3/route_pb'
require 'envoy/config/route/v3/route_components_pb'
require 'envoy/extensions/filters/network/http_connection_manager/v3/http_connection_manager_pb'
require 'envoy/service/discovery/v3/discovery_pb'
require 'envoy/service/load_stats/v3/lrs_pb'
require 'google/protobuf/any_pb'
require 'google/protobuf/duration_pb'
require 'google/protobuf/struct_pb'
require 'google/rpc/status_pb'

module GRPC
  module Core
    # A client for the Aggregated Discovery Service (ADS) and, per cluster,
    # the Load Reporting Service (LRS). There is exactly one instance per
    # process (see .instance) because there is exactly one bootstrap
    # (GRPC_XDS_BOOTSTRAP is a process-wide environment variable) --
    # concurrent xds:// channels for different resource names, and even for
    # different xDS federation authorities, share this one object, though
    # each distinct management server gets its own ADS/LRS connection (see
    # AdsConnection and #connection_for).
    #
    # Out of scope: SDS/mTLS certificate provisioning, RBAC and
    # fault-injection filters, aggregate clusters, a secondary management
    # server on xds_servers[1..], collection resources and incremental xDS
    # (needed for glob collections), and weighted-locality routing beyond
    # flattening every healthy endpoint a cluster's localities name.
    #
    # @api private
    class XdsClient
      Error = Class.new(StandardError)

      TYPE_LISTENER = 'type.googleapis.com/envoy.config.listener.v3.Listener'
      TYPE_ROUTE = 'type.googleapis.com/envoy.config.route.v3.RouteConfiguration'
      TYPE_CLUSTER = 'type.googleapis.com/envoy.config.cluster.v3.Cluster'
      TYPE_ENDPOINT = 'type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment'

      # Returned by #watch_endpoints. +cancel+ drops the subscription so a
      # destroyed Channel's callback is never invoked again; safe to call
      # more than once.
      Watch = Struct.new(:connection, :listener_name, :id) do
        def cancel
          connection.unwatch_endpoints(listener_name, id)
          nil
        end
      end

      DEFAULT_RESOLVE_TIMEOUT = 10

      class << self
        # Parses (and caches) the bootstrap. Called from
        # Transport.parse_target so a bad GRPC_XDS_BOOTSTRAP fails channel
        # construction instead of the first RPC.
        def bootstrap!
          @bootstrap_mu.synchronize { @bootstrap ||= XdsBootstrap.load }
        end

        # The one XdsClient for this process, built (and its default ADS
        # stream started) lazily on first resolve.
        def instance
          @instance_mu.synchronize { @instance ||= new(bootstrap!) }
        end

        # @api private -- specs only, so a bad bootstrap in one example
        # cannot leak a memoized client (or its background threads) into
        # the next.
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
        @config = config
        @node = build_node(config.node)
        @listener_template = config.listener_resource_name_template
        @mu = Mutex.new
        @connections = {}
        default_server = config.servers.first
        fail XdsBootstrap::Error, 'the xDS bootstrap config has no usable xds_servers entry' if default_server.nil?
        @default_connection = connection_for(default_server)
      end

      # Subscribes (if not already) to +listener_name+ and blocks until its
      # LDS -> RDS -> CDS -> EDS chain has resolved to a set of endpoints, or
      # +timeout+ seconds pass. +authority+ selects a federated (gRFC A47)
      # management server from the bootstrap's "authorities" map; nil (the
      # common case) resolves against the top-level xds_servers.
      #
      # @return [Array<Transport::Target>]
      def resolve_endpoints(listener_name, authority: nil, timeout: DEFAULT_RESOLVE_TIMEOUT)
        connection, resolved_name = route_for(listener_name, authority)
        connection.resolve_endpoints(resolved_name, timeout: timeout)
      end

      # Registers +block+ to be called with a fresh
      # Array<Transport::Target> every time a later control-plane push
      # changes +listener_name+'s resolved endpoints -- #resolve_endpoints's
      # initial pull is not repeated here. Routing mirrors
      # #resolve_endpoints so a federated authority watches the same
      # management server it would have resolved against.
      #
      # @return [Watch]
      def watch_endpoints(listener_name, authority: nil, &block)
        connection, resolved_name = route_for(listener_name, authority)
        Watch.new(connection, resolved_name, connection.watch_endpoints(resolved_name, &block))
      end

      def close
        connections = @mu.synchronize { @connections.values }
        connections.each(&:close)
        nil
      end

      private

      # Old-style (no authority) names go to the top-level xds_servers,
      # substituted through client_default_listener_resource_name_template
      # exactly as before federation existed. An authority-qualified name
      # is refused unless the bootstrap's "authorities" map defines it --
      # deliberately checked here (not left to a downstream connect
      # failure) so a channel to an unknown authority fails construction,
      # not the first RPC.
      def route_for(name, authority)
        return [@default_connection, resolved_listener_name(name)] if authority.nil?
        entry = @config.authorities[authority]
        if entry.nil?
          fail Error,
               "xds authority #{authority.inspect} is not defined by the xDS bootstrap's " \
               '"authorities" map'
        end
        server = (entry.servers || @config.servers).first
        [connection_for(server), entry.listener_resource_name_template.sub('%s', percent_encode(name))]
      end

      def resolved_listener_name(name)
        return name if @listener_template.nil? || @listener_template.empty?
        @listener_template.sub('%s', name)
      end

      # The %s a client_listener_resource_name_template substitutes is a
      # URI path segment (gRFC A47): unreserved and sub-delim characters
      # pass through as-is, everything else (chiefly '/', which a plain
      # resource name may itself contain) is percent-encoded so the
      # resulting xdstp:// URI parses as the single path segment it names.
      def percent_encode(name)
        name.gsub(/[^A-Za-z0-9\-._~]/) { |c| c.each_byte.map { |b| format('%%%02X', b) }.join }
      end

      # One AdsConnection per distinct management server -- the same
      # physical server named by two different authorities (or by an
      # authority and the top-level xds_servers) shares its ADS/LRS
      # connection rather than opening a second one.
      def connection_for(server)
        key = [server.server_uri, server.channel_creds_type]
        @mu.synchronize { @connections[key] ||= AdsConnection.new(server, @node) }
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
          list = Google::Protobuf::ListValue.new(values: value.map { |e| json_to_value(e) })
          Google::Protobuf::Value.new(list_value: list)
        else Google::Protobuf::Value.new(string_value: value.to_s)
        end
      end
    end
  end
end

require_relative 'xds_lrs'
require_relative 'xds_ads_connection'
