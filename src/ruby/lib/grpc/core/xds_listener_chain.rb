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
      # The one dependency chain this client resolves: a Listener names a
      # RouteConfiguration (by RDS name, or inline), a RouteConfiguration's
      # first plausibly-matching route names a Cluster, and a Cluster names
      # an EDS ClusterLoadAssignment. Each link's resource name is looked up
      # through XdsClient's own resource cache/subscription registry
      # (#subscribe_for), which is what actually decides -- from the name
      # itself, gRFC A47 -- which management server it comes from; this
      # class only walks the chain and computes the endpoints at the end of
      # it. One instance is shared by every #resolve_endpoints/
      # #watch_endpoints caller for the same fully-resolved listener name
      # (see XdsClient#chain_for).
      #
      # @api private
      class ListenerChain
        TYPE_LISTENER = XdsClient::TYPE_LISTENER
        TYPE_ROUTE = XdsClient::TYPE_ROUTE
        TYPE_CLUSTER = XdsClient::TYPE_CLUSTER
        TYPE_ENDPOINT = XdsClient::TYPE_ENDPOINT

        # A cluster's endpoints are unusable in these health states; see
        # envoy/config/core/v3/health_check.proto's HealthStatus. UNKNOWN
        # (0) and HEALTHY (1) pass, DEGRADED (5) passes too since dropping
        # it entirely would be worse than an eds-only client without full
        # weighted-priority support picking a degraded endpoint.
        UNUSABLE_HEALTH_STATUSES = [2, 3, 4].freeze # UNHEALTHY, DRAINING, TIMEOUT

        def initialize(xds_client, listener_name)
          @xds_client = xds_client
          @name = listener_name
          @id = Object.new

          @mu = Mutex.new
          @cv = ConditionVariable.new
          @cluster_connection = nil # whichever AdsConnection last delivered our Cluster, for its LRS counter
          @addresses = nil
          @watchers = {}

          subscribe_type(TYPE_LISTENER, @name) { |listener, _connection| on_listener(listener) }
        end

        # Blocks until this chain's LDS -> RDS -> CDS -> EDS walk has
        # resolved to a set of endpoints, or +timeout+ seconds pass.
        #
        # @return [Array<Transport::Target>]
        def resolve(timeout)
          deadline = RpcStream.now + timeout
          @mu.synchronize do
            loop do
              return @addresses unless @addresses.nil?
              remaining = deadline - RpcStream.now
              fail XdsClient::Error, "xDS resolution of #{@name.inspect} timed out" if remaining <= 0
              @cv.wait(@mu, [remaining, 0.05].min)
            end
          end
        end

        # Registers +block+ to be called, from whichever thread is handling
        # the response that changed things, with a fresh
        # Array<Transport::Target> every time a later control-plane push
        # changes this chain's resolved endpoints -- #resolve's initial
        # pull is not repeated here (a caller that registers after the
        # first successful #resolve has already missed nothing, since
        # nothing has changed since).
        def watch(&block)
          id = Object.new
          @mu.synchronize { @watchers[id] = block }
          id
        end

        def unwatch(id)
          @mu.synchronize { @watchers.delete(id) }
          nil
        end

        private

        # Subscribes to +name+ of +type_url+ and, if it is already cached
        # (a watcher joining a chain another caller already resolved, or a
        # later link within this same chain that happened to be filled in
        # already), invokes +block+ immediately -- outside XdsClient's own
        # lock, since #subscribe_for released it before returning.
        def subscribe_type(type_url, name, &block)
          value, connection = @xds_client.subscribe_for(type_url, name, @id, &block)
          block.call(value, connection) unless value.nil?
        end

        def on_listener(listener)
          any = listener.api_listener&.api_listener
          return if any.nil?
          hcm = decode_hcm(any)
          return if hcm.nil?
          case hcm.route_specifier
          when :rds
            subscribe_type(TYPE_ROUTE, hcm.rds.route_config_name) { |route, _connection| on_route(route) }
          when :route_config
            # An inline route_config never travels over the wire under its
            # own name, so it is followed directly instead of subscribed
            # to.
            on_route(hcm.route_config)
          end
        end

        # A Listener's ApiListener wraps an HttpConnectionManager as an
        # Any; this reaches into it for the RDS route_config_name (or the
        # inline route_config), the only piece this client needs.
        def decode_hcm(any)
          Envoy::Extensions::Filters::Network::HttpConnectionManager::V3::HttpConnectionManager.decode(any.value)
        rescue Google::Protobuf::ParseError
          nil
        end

        def on_route(route_config)
          cluster_name = cluster_name_of(route_config)
          return if cluster_name.nil?
          subscribe_type(TYPE_CLUSTER, cluster_name) { |cluster, connection| on_cluster(cluster, connection) }
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

        def on_cluster(cluster, connection)
          eds_name = cluster.eds_cluster_config&.service_name
          eds_name = cluster.name if eds_name.nil? || eds_name.empty?
          connection&.note_lrs(cluster)
          @mu.synchronize { @cluster_connection = connection }
          subscribe_type(TYPE_ENDPOINT, eds_name) { |cla, _connection| on_endpoint(cla) }
        end

        def on_endpoint(cla)
          counter = @mu.synchronize { @cluster_connection }&.lrs_counter_for(cla.cluster_name)
          addresses = endpoints_of(cla, counter)
          callbacks = @mu.synchronize do
            next [] if addresses == @addresses
            @addresses = addresses
            @cv.broadcast
            @watchers.values
          end
          callbacks.each { |block| block.call(addresses) }
        end

        def endpoints_of(cla, lrs_counter)
          cla.endpoints.flat_map do |locality|
            locality.lb_endpoints
                    .reject { |lbe| UNUSABLE_HEALTH_STATUSES.include?(lbe.health_status) }
                    .filter_map { |lbe| target_of(lbe, lrs_counter) }
          end
        end

        def target_of(lb_endpoint, lrs_counter)
          socket_address = lb_endpoint.endpoint&.address&.socket_address
          return nil if socket_address.nil?
          Transport::Target.new(:tcp, socket_address.address, socket_address.port_value, nil, nil,
                                lb_endpoint.load_balancing_weight&.value, nil, lrs_counter)
        end
      end
    end
  end
end
