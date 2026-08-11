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

# A fake Aggregated Discovery Service the xDS conformance harness (run.rb)
# drives to prove the client-observable LB behaviours run_xds_tests.py
# checks: ping_pong, round_robin, backends_restart and moving/adding
# endpoints (remove_instance_group/change_backend_service/
# new_instance_group_receives_traffic all reduce, at the xDS layer, to an
# EDS update).
#
# This mirrors spec/xds_spec.rb's XdsFakeManagementServer -- same
# GRPC::GenericService shape, same request log, same responder-per-type_url
# registration -- but adds #push, which sends a DiscoveryResponse to every
# live stream right now rather than only in reply to an incoming request.
# That is what a real management server does when a resource changes under
# a client that already subscribed to it, and it is exactly what moving
# traffic mid-run needs. It is not folded back into xds_spec.rb: #push
# requires a queue and a dedicated reader thread per stream, and
# xds_spec.rb's "does not leak the ADS stream connection past a reconnect"
# test asserts an exact Thread.list.size before and after a stream ends --
# an assertion this class's extra thread would make far more brittle for a
# spec that has nothing to do with server-initiated pushes.
class XdsFakeControlPlane
  include GRPC::GenericService
  self.marshal_class_method = :encode
  self.unmarshal_class_method = :decode
  self.service_name = 'envoy.service.discovery.v3.AggregatedDiscoveryService'

  Req = Envoy::Service::Discovery::V3::DiscoveryRequest
  Resp = Envoy::Service::Discovery::V3::DiscoveryResponse

  rpc :StreamAggregatedResources, stream(Req), stream(Resp)

  attr_reader :requests

  def initialize
    @mu = Mutex.new
    @requests = []
    @responders = {}
    @streams = []
  end

  # Registers +blk+, called as (request, stream_index) -> [responses, stop],
  # for every DiscoveryRequest naming +type_url+.
  def on(type_url, &blk)
    @mu.synchronize { @responders[type_url] = blk }
  end

  # Sends +response+ to every currently connected stream immediately,
  # without waiting for a request -- the unsolicited push a real management
  # server makes when a resource it already sent changes underneath a
  # subscribed client.
  def push(response)
    @mu.synchronize { @streams.dup }.each { |queue| queue << response }
  end

  def stream_aggregated_resources(requests, _call)
    stream_index = @mu.synchronize { (@stream_index ||= 0) + 1 }
    @mu.synchronize { @stream_index = stream_index }
    queue = Queue.new
    @mu.synchronize { @streams << queue }
    reader = Thread.new do
      requests.each do |req|
        @mu.synchronize { @requests << req }
        responder = @mu.synchronize { @responders[req.type_url] }
        next if responder.nil?
        responses, stop = responder.call(req, stream_index)
        responses.each { |resp| queue << resp }
        break if stop
      end
    rescue StandardError
      # The client dropped the connection; let the Enumerator below end.
    ensure
      queue << :done
    end
    Enumerator.new do |y|
      loop do
        item = queue.pop
        break if item == :done
        y << item
      end
    ensure
      @mu.synchronize { @streams.delete(queue) }
      reader.kill if reader.alive?
    end
  end
end
XdsFakeControlPlaneStub = XdsFakeControlPlane.rpc_stub_class

# A stateful convenience layer over XdsFakeControlPlane: serves one
# listener -> route -> EDS-cluster chain, tracks the version/nonce for each
# resource type itself, and answers every fresh subscription (including a
# resubscription after a dropped connection) with whatever it currently
# holds. #set_endpoints re-serves the EDS resource at a new version and
# pushes it to any already-connected stream, moving traffic without the
# client reconnecting -- the one thing every non-static run_xds_tests.py
# case needs.
class XdsConformanceControlPlane
  LDS = GRPC::Core::XdsClient::TYPE_LISTENER
  RDS = GRPC::Core::XdsClient::TYPE_ROUTE
  CDS = GRPC::Core::XdsClient::TYPE_CLUSTER
  EDS = GRPC::Core::XdsClient::TYPE_ENDPOINT

  LISTENER_NAME = 'xds-conformance-listener'
  ROUTE_NAME = 'xds-conformance-route'
  CLUSTER_NAME = 'xds-conformance-cluster'

  attr_reader :uri

  def initialize
    @mu = Mutex.new
    @versions = Hash.new(0)
    @current = {}
    @control_plane = XdsFakeControlPlane.new
    @rpc_server = GRPC::RpcServer.new(poll_period: 1)
    port = @rpc_server.add_http2_port('0.0.0.0:0', :this_port_is_insecure)
    @rpc_server.handle(@control_plane)
    @thread = Thread.new { @rpc_server.run }
    @rpc_server.wait_till_running
    @uri = "0.0.0.0:#{port}"

    [LDS, RDS, CDS, EDS].each do |type_url|
      @control_plane.on(type_url) do |req, _stream_index|
        # Only a fresh subscription (first request for this type, or a
        # resubscription after the stream reconnected) needs a reply here;
        # updates to an already-acknowledged resource go out through #push
        # instead, exactly as an unsolicited server push would.
        next [[], false] unless req.response_nonce.empty?
        resp = @mu.synchronize { @current[type_url] }
        resp.nil? ? [[], false] : [[resp], false]
      end
    end

    set(LDS, listener_resource)
    set(RDS, route_config_resource)
    set(CDS, cluster_resource)
  end

  # Publishes +backends+ (an Array of "host:port" strings) as the cluster's
  # endpoint set, replacing whatever it served before.
  def set_endpoints(backends)
    set(EDS, endpoint_resource(backends))
  end

  def stop
    @rpc_server.stop
    @thread.join(5)
  end

  private

  def set(type_url, resource)
    resp = @mu.synchronize do
      @versions[type_url] += 1
      version = @versions[type_url]
      resp = Envoy::Service::Discovery::V3::DiscoveryResponse.new(
        version_info: version.to_s, type_url: type_url, nonce: "n-#{version}",
        resources: [Google::Protobuf::Any.new(type_url: type_url, value: resource.class.encode(resource))]
      )
      @current[type_url] = resp
      resp
    end
    @control_plane.push(resp)
  end

  def listener_resource
    hcm = Envoy::Extensions::Filters::Network::HttpConnectionManager::V3::HttpConnectionManager.new(
      rds: Envoy::Extensions::Filters::Network::HttpConnectionManager::V3::Rds.new(route_config_name: ROUTE_NAME)
    )
    Envoy::Config::Listener::V3::Listener.new(
      name: LISTENER_NAME,
      api_listener: Envoy::Config::Listener::V3::ApiListener.new(
        api_listener: Google::Protobuf::Any.new(
          type_url: 'type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager',
          value: hcm.class.encode(hcm)
        )
      )
    )
  end

  def route_config_resource
    Envoy::Config::Route::V3::RouteConfiguration.new(
      name: ROUTE_NAME,
      virtual_hosts: [
        Envoy::Config::Route::V3::VirtualHost.new(
          name: 'vh', domains: ['*'],
          routes: [
            Envoy::Config::Route::V3::Route.new(
              match: Envoy::Config::Route::V3::RouteMatch.new(prefix: '/'),
              route: Envoy::Config::Route::V3::RouteAction.new(cluster: CLUSTER_NAME)
            )
          ]
        )
      ]
    )
  end

  def cluster_resource
    Envoy::Config::Cluster::V3::Cluster.new(
      name: CLUSTER_NAME, type: :EDS,
      eds_cluster_config: Envoy::Config::Cluster::V3::Cluster::EdsClusterConfig.new(service_name: CLUSTER_NAME)
    )
  end

  def endpoint_resource(backends)
    lb_endpoints = backends.map do |address|
      host, port = address.split(':')
      Envoy::Config::Endpoint::V3::LbEndpoint.new(
        health_status: :HEALTHY,
        endpoint: Envoy::Config::Endpoint::V3::Endpoint.new(
          address: Envoy::Config::Core::V3::Address.new(
            socket_address: Envoy::Config::Core::V3::SocketAddress.new(address: host, port_value: port.to_i)
          )
        )
      )
    end
    Envoy::Config::Endpoint::V3::ClusterLoadAssignment.new(
      cluster_name: CLUSTER_NAME,
      endpoints: [Envoy::Config::Endpoint::V3::LocalityLbEndpoints.new(lb_endpoints: lb_endpoints)]
    )
  end
end
