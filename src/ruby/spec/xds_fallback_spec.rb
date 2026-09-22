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

require 'spec_helper'
require 'grpc/core/xds_client'
require 'json'
require 'socket'

# gRFC A71 fallback: an authority's ordered server list, one persistent
# Channel per server actually in play, adding the next server only when the
# active one fails *and* something is still uncached, and reverting (closing
# the fallback channel) the moment a higher-priority server answers again.
#
# A minimal, independently-controllable ADS fake -- see xds_spec.rb's
# XdsFakeManagementServer for the fuller version this trims from. Named
# distinctly (rspec loads every spec file into one process; top-level class
# names must stay unique across the whole suite -- see xds_lrs_spec.rb).
class XdsFallbackFakeServer
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
    @push_queues = []
  end

  # Registers +blk+, called as (request) -> [responses, stop], for every
  # DiscoveryRequest naming +type_url+. +stop+ true ends the stream right
  # after.
  def on(type_url, &blk)
    @mu.synchronize { @responders[type_url] = blk }
  end

  # Sends +resp+ on every currently-open stream, without waiting for a
  # request -- a real control plane's admin API (SetResources) updates an
  # already-subscribed resource by pushing over the open ADS stream, not
  # by waiting to be asked again; this is the fake's analogue.
  def push(resp)
    @mu.synchronize { @push_queues.dup }.each { |q| q.push(resp) }
  end

  # Severs every currently-open connection right now -- a stand-in for a
  # real control plane's StopOnResourceRequest, which exits the whole
  # process. Spawned on its own thread since +rpc_server+.stop waits for
  # in-flight calls (this one included) to finish.
  def kill_now(rpc_server)
    Thread.new { rpc_server.stop }
  end

  def stream_aggregated_resources(requests, _call)
    push_queue = Queue.new
    @mu.synchronize { @push_queues << push_queue }
    reader = Thread.new do
      requests.each do |req|
        @mu.synchronize { @requests << req }
        responder = @mu.synchronize { @responders[req.type_url] }
        next if responder.nil?
        responses, stop = responder.call(req)
        responses.each { |resp| push_queue.push(resp) }
        push_queue.push(:stop) if stop
      end
      push_queue.push(:stop)
    rescue StandardError
      push_queue.push(:stop)
    end
    Enumerator.new do |y|
      loop do
        item = push_queue.pop
        break if item == :stop
        y << item
      end
    ensure
      @mu.synchronize { @push_queues.delete(push_queue) }
      reader.kill
    end
  end
end

XDS_FB_LDS = GRPC::Core::XdsClient::TYPE_LISTENER
XDS_FB_RDS = GRPC::Core::XdsClient::TYPE_ROUTE
XDS_FB_CDS = GRPC::Core::XdsClient::TYPE_CLUSTER
XDS_FB_EDS = GRPC::Core::XdsClient::TYPE_ENDPOINT
XDS_FB_LISTENER = 'fallback-service'

describe 'xDS fallback (gRFC A71)' do
  include GRPC::Spec::Helpers

  def any_for(type_url, message)
    Google::Protobuf::Any.new(type_url: type_url, value: message.class.encode(message))
  end

  def response_for(type_url, message, version:, nonce:)
    XdsFallbackFakeServer::Resp.new(version_info: version, type_url: type_url, nonce: nonce,
                                    resources: [any_for(type_url, message)])
  end

  def ack_only_responder(type_url, resource, version:, nonce:)
    lambda do |req|
      if req.response_nonce.empty?
        [[response_for(type_url, resource, version: version, nonce: nonce)], false]
      else
        [[], false]
      end
    end
  end

  def listener_resource(route_config_name:, name: XDS_FB_LISTENER)
    hcm = Envoy::Extensions::Filters::Network::HttpConnectionManager::V3::HttpConnectionManager.new(
      rds: Envoy::Extensions::Filters::Network::HttpConnectionManager::V3::Rds.new(
        route_config_name: route_config_name
      )
    )
    Envoy::Config::Listener::V3::Listener.new(
      name: name,
      api_listener: Envoy::Config::Listener::V3::ApiListener.new(
        api_listener: any_for(
          'type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager',
          hcm
        )
      )
    )
  end

  def route_config_resource(name:, cluster_name:)
    Envoy::Config::Route::V3::RouteConfiguration.new(
      name: name,
      virtual_hosts: [
        Envoy::Config::Route::V3::VirtualHost.new(
          name: 'vh', domains: ['*'],
          routes: [
            Envoy::Config::Route::V3::Route.new(
              match: Envoy::Config::Route::V3::RouteMatch.new(prefix: '/'),
              route: Envoy::Config::Route::V3::RouteAction.new(cluster: cluster_name)
            )
          ]
        )
      ]
    )
  end

  def cluster_resource(name:)
    Envoy::Config::Cluster::V3::Cluster.new(
      name: name, type: :EDS,
      eds_cluster_config: Envoy::Config::Cluster::V3::Cluster::EdsClusterConfig.new(service_name: name)
    )
  end

  def endpoint_resource(name:, port:, address: '127.0.0.1')
    Envoy::Config::Endpoint::V3::ClusterLoadAssignment.new(
      cluster_name: name,
      endpoints: [
        Envoy::Config::Endpoint::V3::LocalityLbEndpoints.new(
          lb_endpoints: [
            Envoy::Config::Endpoint::V3::LbEndpoint.new(
              health_status: :HEALTHY,
              endpoint: Envoy::Config::Endpoint::V3::Endpoint.new(
                address: Envoy::Config::Core::V3::Address.new(
                  socket_address: Envoy::Config::Core::V3::SocketAddress.new(address: address, port_value: port)
                )
              )
            )
          ]
        )
      ]
    )
  end

  # Serves +fake+'s full LDS -> RDS -> CDS -> EDS chain for XDS_FB_LISTENER,
  # naming +cluster_name+ and answering EDS with +port+ -- one call sets up
  # an entire management server's worth of config.
  def serve_full_chain(fake, cluster_name:, port:, route_name: "route-#{cluster_name}")
    fake.on(XDS_FB_LDS, &ack_only_responder(XDS_FB_LDS, listener_resource(route_config_name: route_name),
                                            version: 'v1', nonce: 'n-lds-1'))
    fake.on(XDS_FB_RDS, &ack_only_responder(XDS_FB_RDS, route_config_resource(name: route_name, cluster_name: cluster_name),
                                            version: 'v1', nonce: 'n-rds-1'))
    fake.on(XDS_FB_CDS, &ack_only_responder(XDS_FB_CDS, cluster_resource(name: cluster_name),
                                            version: 'v1', nonce: 'n-cds-1'))
    fake.on(XDS_FB_EDS, &ack_only_responder(XDS_FB_EDS, endpoint_resource(name: cluster_name, port: port),
                                            version: 'v1', nonce: 'n-eds-1'))
  end

  # A bound-but-unlistened port: nothing answers there, so a connection
  # attempt fails fast (ECONNREFUSED) rather than timing out -- the
  # "primary is down from the very start" half of gRFC A71's fallback
  # trigger.
  def dead_port
    s = TCPServer.new('0.0.0.0', 0)
    port = s.addr[1]
    s.close
    port
  end

  def spawn_fake(fake, port: 0)
    server = GRPC::RpcServer.new(poll_period: 1)
    actual_port = server.add_http2_port("0.0.0.0:#{port}", :this_port_is_insecure)
    server.handle(fake)
    thread = Thread.new { server.run }
    server.wait_till_running
    @servers << [server, thread]
    [server, thread, actual_port]
  end

  def stop_all_servers
    @servers.each do |server, thread|
      server.stop
      thread.join(5)
    rescue StandardError
      nil
    end
    @servers = []
  end

  def configure_bootstrap(server_uris)
    config = {
      'xds_servers' => server_uris.map { |uri| { 'server_uri' => uri, 'channel_creds' => [{ 'type' => 'insecure' }] } },
      'node' => { 'id' => 'xds-fallback-spec-node' }
    }
    ENV['GRPC_XDS_BOOTSTRAP_CONFIG'] = config.to_json
  end

  def wait_until(timeout: 10)
    deadline = GRPC::Core::RpcStream.now + timeout
    sleep(0.02) until yield || GRPC::Core::RpcStream.now >= deadline
  end

  # The live channelz Channel whose #target is exactly +uri+, or nil.
  def channelz_channel_for(uri)
    GRPC::Core::Channelz.channels_from(0).map { |_id, ch| ch }.find { |ch| ch.target == uri }
  end

  before(:each) do
    GRPC::Core::XdsClient.reset_for_testing!
    @servers = []
  end

  after(:each) do
    GRPC::Core::XdsClient.reset_for_testing!
    stop_all_servers
    ENV.delete('GRPC_XDS_BOOTSTRAP_CONFIG')
  end

  it 'adds the fallback server when the primary is unreachable from the start, and serves its config' do
    primary_uri = "0.0.0.0:#{dead_port}"
    secondary = XdsFallbackFakeServer.new
    _server, _thread, secondary_port = spawn_fake(secondary)
    secondary_uri = "0.0.0.0:#{secondary_port}"
    serve_full_chain(secondary, cluster_name: 'secondary-cluster', port: 21_100)

    configure_bootstrap([primary_uri, secondary_uri])

    addresses = GRPC::Core::XdsClient.instance.resolve_endpoints(XDS_FB_LISTENER, timeout: 15)
    expect(addresses.map { |a| [a.host, a.port] }).to eq([['127.0.0.1', 21_100]])
    expect(secondary.requests).not_to be_empty

    # The primary is still being retried, not abandoned: its Channel
    # exists in channelz (a persistent connection per server, gRFC A71),
    # even though it has never once succeeded.
    wait_until { !channelz_channel_for(primary_uri).nil? }
    primary_channel = channelz_channel_for(primary_uri)
    expect(primary_channel).not_to be_nil
    wait_until { primary_channel.connectivity_state(false) == GRPC::Core::ConnectivityStates::TRANSIENT_FAILURE }
    expect(primary_channel.connectivity_state(false)).to eq(GRPC::Core::ConnectivityStates::TRANSIENT_FAILURE)
  end

  it 'does not fall back once every resource is already cached, even after the primary dies' do
    primary = XdsFallbackFakeServer.new
    primary_server, primary_thread, primary_port = spawn_fake(primary)
    primary_uri = "0.0.0.0:#{primary_port}"
    serve_full_chain(primary, cluster_name: 'primary-cluster', port: 21_101)

    secondary = XdsFallbackFakeServer.new
    _server, _thread, secondary_port = spawn_fake(secondary)
    secondary_uri = "0.0.0.0:#{secondary_port}"
    # Deliberately no responders registered: if the client ever contacts
    # this server at all, #requests stops being empty.

    configure_bootstrap([primary_uri, secondary_uri])

    addresses = GRPC::Core::XdsClient.instance.resolve_endpoints(XDS_FB_LISTENER, timeout: 10)
    expect(addresses.map { |a| [a.host, a.port] }).to eq([['127.0.0.1', 21_101]])

    primary_channel = channelz_channel_for(primary_uri)
    expect(primary_channel).not_to be_nil

    primary_server.stop
    primary_thread.join(5)
    wait_until { primary_channel.connectivity_state(false) == GRPC::Core::ConnectivityStates::TRANSIENT_FAILURE }
    expect(primary_channel.connectivity_state(false)).to eq(GRPC::Core::ConnectivityStates::TRANSIENT_FAILURE)

    # Give a would-be (wrong) fallback plenty of time to have shown up.
    sleep 1
    expect(secondary.requests).to be_empty
    expect(channelz_channel_for(secondary_uri)).to be_nil
  end

  it 'reverts to the primary once it becomes healthy again, closing the fallback channel' do
    primary_port = dead_port
    primary_uri = "0.0.0.0:#{primary_port}"

    secondary = XdsFallbackFakeServer.new
    _server, _thread, secondary_port = spawn_fake(secondary)
    secondary_uri = "0.0.0.0:#{secondary_port}"
    serve_full_chain(secondary, cluster_name: 'secondary-cluster', port: 21_102)

    configure_bootstrap([primary_uri, secondary_uri])

    watch = GRPC::Core::XdsClient.instance.watch_endpoints(XDS_FB_LISTENER) { |addrs| @pushed = addrs }
    addresses = GRPC::Core::XdsClient.instance.resolve_endpoints(XDS_FB_LISTENER, timeout: 15)
    expect(addresses.map { |a| [a.host, a.port] }).to eq([['127.0.0.1', 21_102]])

    secondary_channel = channelz_channel_for(secondary_uri)
    expect(secondary_channel).not_to be_nil
    wait_until { secondary_channel.connectivity_state(false) == GRPC::Core::ConnectivityStates::READY }

    # The primary comes back, on the exact port the bootstrap already
    # names, serving a different config.
    primary = XdsFallbackFakeServer.new
    spawn_fake(primary, port: primary_port)
    serve_full_chain(primary, cluster_name: 'primary-cluster', port: 21_103)

    wait_until(timeout: 15) { !@pushed.nil? && @pushed.map { |a| [a.host, a.port] } == [['127.0.0.1', 21_103]] }
    expect(@pushed.map { |a| [a.host, a.port] }).to eq([['127.0.0.1', 21_103]])

    # The fallback server's channel is gone -- not just unhealthy --
    # exactly once it is no longer needed.
    wait_until { channelz_channel_for(secondary_uri).nil? }
    expect(channelz_channel_for(secondary_uri)).to be_nil
    watch.cancel
  end

  it 'falls back mid-update when the primary severs the connection over a newly-referenced resource' do
    primary = XdsFallbackFakeServer.new
    primary_server, _thread, primary_port = spawn_fake(primary)
    primary_uri = "0.0.0.0:#{primary_port}"
    serve_full_chain(primary, cluster_name: 'primary-cluster-1', port: 21_104)

    secondary = XdsFallbackFakeServer.new
    _server, _thread, secondary_port = spawn_fake(secondary)
    secondary_uri = "0.0.0.0:#{secondary_port}"
    serve_full_chain(secondary, cluster_name: 'secondary-cluster', port: 21_105)

    configure_bootstrap([primary_uri, secondary_uri])

    watch = GRPC::Core::XdsClient.instance.watch_endpoints(XDS_FB_LISTENER) { |addrs| @pushed = addrs }
    addresses = GRPC::Core::XdsClient.instance.resolve_endpoints(XDS_FB_LISTENER, timeout: 10)
    expect(addresses.map { |a| [a.host, a.port] }).to eq([['127.0.0.1', 21_104]])

    # The primary announces (an unprompted push over the still-open ADS
    # stream, exactly like a real control plane's SetResources admin
    # call) an update to the route the client already watches -- a
    # resource update to a name nobody subscribed to would simply be
    # ignored -- naming an as-yet-uncached cluster, then severs the
    # connection the moment that cluster is actually asked for: a real
    # control plane's StopOnResourceRequest, simplified to what this fake
    # can express (see XdsFallbackFakeServer#kill_now).
    primary.on(XDS_FB_CDS) do |req|
      if req.resource_names.include?('primary-cluster-2')
        primary.kill_now(primary_server)
      end
      [[], false]
    end
    primary.push(response_for(XDS_FB_RDS, route_config_resource(name: 'route-primary-cluster-1', cluster_name: 'primary-cluster-2'),
                              version: 'v2', nonce: 'n-rds-2'))

    wait_until(timeout: 20) { primary.requests.any? { |r| r.type_url == XDS_FB_CDS && r.resource_names.include?('primary-cluster-2') } }
    expect(primary.requests.map(&:type_url)).to include(XDS_FB_CDS)

    wait_until(timeout: 20) { !@pushed.nil? && @pushed.map { |a| [a.host, a.port] } == [['127.0.0.1', 21_105]] }
    expect(@pushed.map { |a| [a.host, a.port] }).to eq([['127.0.0.1', 21_105]])
    watch.cancel
  end
end
