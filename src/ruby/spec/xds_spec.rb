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
# The xds client is loaded on demand by Transport, so a spec that names its
# constants directly has to ask for it.
require 'grpc/core/xds_client'
require 'json'

# xds:/// used to be rejected outright: no bootstrap, no management-server
# connection, nothing resolved. This proves the whole chain instead --
# bootstrap parsing, the ADS bidi stream's request/response cycle with
# version_info/nonce, ACK and NACK, reconnect-with-resubscribe, and the
# resolved endpoints reaching Transport the same way a DNS answer would.
#
# A minimal Aggregated Discovery Service: every incoming DiscoveryRequest is
# handed to whatever responder #on registered for its type_url, which
# decides what (if anything) to send back and whether the stream should end
# there (simulating the management server dropping the connection). Every
# request that arrives, across every stream, is recorded for the spec to
# inspect the ACK/NACK version_info and nonce it carried.
class XdsFakeManagementServer
  include GRPC::GenericService
  self.marshal_class_method = :encode
  self.unmarshal_class_method = :decode
  self.service_name = 'envoy.service.discovery.v3.AggregatedDiscoveryService'

  Req = Envoy::Service::Discovery::V3::DiscoveryRequest
  Resp = Envoy::Service::Discovery::V3::DiscoveryResponse

  rpc :StreamAggregatedResources, stream(Req), stream(Resp)

  attr_reader :requests, :stream_count

  def initialize
    @mu = Mutex.new
    @requests = []
    @stream_count = 0
    @responders = {}
  end

  # Registers +blk+, called as (request, stream_index) -> [responses, stop],
  # for every DiscoveryRequest naming +type_url+. +responses+ is an Array of
  # DiscoveryResponse to send immediately; +stop+ ends the stream right
  # after (simulating a dropped connection) when true.
  def on(type_url, &blk)
    @mu.synchronize { @responders[type_url] = blk }
  end

  def stream_aggregated_resources(requests, _call)
    stream_index = @mu.synchronize { @stream_count += 1 }
    Enumerator.new do |y|
      requests.each do |req|
        @mu.synchronize { @requests << req }
        responder = @mu.synchronize { @responders[req.type_url] }
        next if responder.nil?
        responses, stop = responder.call(req, stream_index)
        responses.each { |resp| y << resp }
        break if stop
      end
    end
  end
end
XdsFakeManagementServerStub = XdsFakeManagementServer.rpc_stub_class

XDS_LDS = GRPC::Core::XdsClient::TYPE_LISTENER
XDS_RDS = GRPC::Core::XdsClient::TYPE_ROUTE
XDS_CDS = GRPC::Core::XdsClient::TYPE_CLUSTER
XDS_EDS = GRPC::Core::XdsClient::TYPE_ENDPOINT

XDS_LISTENER_NAME = 'my-service'
XDS_ROUTE_NAME = 'my-route'
XDS_CLUSTER_NAME = 'my-cluster'

describe 'xds' do
  include GRPC::Spec::Helpers

  def any_for(type_url, message)
    Google::Protobuf::Any.new(type_url: type_url, value: message.class.encode(message))
  end

  def response_for(type_url, message, version:, nonce:)
    XdsFakeManagementServer::Resp.new(
      version_info: version, type_url: type_url, nonce: nonce,
      resources: [any_for(type_url, message)]
    )
  end

  def listener_resource(name: XDS_LISTENER_NAME, route_config_name: XDS_ROUTE_NAME)
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

  def route_config_resource(name: XDS_ROUTE_NAME, cluster_name: XDS_CLUSTER_NAME)
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

  def cluster_resource(name: XDS_CLUSTER_NAME)
    Envoy::Config::Cluster::V3::Cluster.new(
      name: name, type: :EDS,
      eds_cluster_config: Envoy::Config::Cluster::V3::Cluster::EdsClusterConfig.new(service_name: name)
    )
  end

  def endpoint_resource(name: XDS_CLUSTER_NAME, address: '127.0.0.1', port: 21_000)
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

  # A responder for the common case: the first request for a type (empty
  # nonce) gets +resource+ back at +version+/+nonce+; the ACK that follows
  # (matching nonce, no error_detail) gets nothing.
  def ack_only_responder(type_url, resource, version:, nonce:)
    lambda do |req, _stream_index|
      if req.response_nonce.empty?
        [[response_for(type_url, resource, version: version, nonce: nonce)], false]
      else
        [[], false]
      end
    end
  end

  def start_management_server(&block)
    @management = XdsFakeManagementServer.new
    @host = "0.0.0.0:#{spawn_management_server(0)}"
    block.call
  ensure
    stop_management_server
  end

  def spawn_management_server(port)
    server = GRPC::RpcServer.new(poll_period: 1)
    actual_port = server.add_http2_port("0.0.0.0:#{port}", :this_port_is_insecure)
    server.handle(@management)
    thread = Thread.new { server.run }
    server.wait_till_running
    @rpc_server = server
    @rpc_server_thread = thread
    @management_port = actual_port
  end

  def stop_management_server
    return if @rpc_server.nil?
    @rpc_server.stop
    @rpc_server_thread.join(5)
    @rpc_server = nil
  end

  # A second, independent management server for the federation
  # (authority-qualified target) test: a distinct XdsFakeManagementServer
  # so requests to it are never conflated with @management's.
  def start_extra_management_server
    management = XdsFakeManagementServer.new
    server = GRPC::RpcServer.new(poll_period: 1)
    port = server.add_http2_port('0.0.0.0:0', :this_port_is_insecure)
    server.handle(management)
    thread = Thread.new { server.run }
    server.wait_till_running
    @extra_servers << [server, thread]
    [management, "0.0.0.0:#{port}"]
  end

  def stop_extra_management_servers
    @extra_servers.each do |server, thread|
      server.stop
      thread.join(5)
    end
    @extra_servers = []
  end

  # A clean app-level end of the response stream leaves the underlying
  # HTTP/2 stream half-open (the client can still write) rather than
  # tearing anything down, so it is not a faithful stand-in for "the
  # management server dropped the connection". Actually closing the
  # listening server's connections and rebinding on the same port is: the
  # client's socket sees a real close, and the reconnect that follows
  # lands on a fresh server while @management keeps recording every
  # request across both.
  def drop_management_connection
    port = @management_port
    stop_management_server
    spawn_management_server(port)
  end

  def configure_bootstrap(server_uri: @host, authorities: nil)
    config = {
      'xds_servers' => [{ 'server_uri' => server_uri, 'channel_creds' => [{ 'type' => 'insecure' }] }],
      'node' => { 'id' => 'xds-spec-node' }
    }
    config['authorities'] = authorities unless authorities.nil?
    ENV['GRPC_XDS_BOOTSTRAP_CONFIG'] = config.to_json
  end

  def wait_until(timeout: 5)
    deadline = GRPC::Core::RpcStream.now + timeout
    sleep(0.02) until yield || GRPC::Core::RpcStream.now >= deadline
  end

  before(:each) do
    GRPC::Core::XdsClient.reset_for_testing!
    @extra_servers = []
  end

  after(:each) do
    GRPC::Core::XdsClient.reset_for_testing!
    stop_management_server
    stop_extra_management_servers
    ENV.delete('GRPC_XDS_BOOTSTRAP_CONFIG')
    ENV.delete('GRPC_XDS_BOOTSTRAP')
  end

  it 'resolves an xds:/// target to the endpoints EDS returns, via LDS -> RDS -> CDS -> EDS' do
    start_management_server do
      configure_bootstrap
      @management.on(XDS_LDS, &ack_only_responder(XDS_LDS, listener_resource, version: 'v1', nonce: 'n-lds-1'))
      @management.on(XDS_RDS, &ack_only_responder(XDS_RDS, route_config_resource, version: 'v1', nonce: 'n-rds-1'))
      @management.on(XDS_CDS, &ack_only_responder(XDS_CDS, cluster_resource, version: 'v1', nonce: 'n-cds-1'))
      @management.on(XDS_EDS, &ack_only_responder(XDS_EDS, endpoint_resource(port: 21_001), version: 'v1', nonce: 'n-eds-1'))

      target = GRPC::Core::Transport.parse_target("xds:///#{XDS_LISTENER_NAME}")
      addresses = GRPC::Core::Transport.resolve_addresses(target)

      expect(addresses.map { |a| [a.host, a.port] }).to eq([['127.0.0.1', 21_001]])

      # #resolve_addresses returns as soon as the EDS ACK is enqueued, not
      # once the management server has actually received it over the wire.
      wait_until { @management.requests.count { |r| !r.response_nonce.empty? } >= 4 }

      # Every ACK carries the version_info and nonce the response it
      # accepted was sent with, and no error_detail.
      acks = @management.requests.select { |r| !r.response_nonce.empty? && r.error_detail.nil? }
      expect(acks.map { |r| [r.type_url, r.version_info, r.response_nonce] }).to contain_exactly(
        [XDS_LDS, 'v1', 'n-lds-1'], [XDS_RDS, 'v1', 'n-rds-1'], [XDS_CDS, 'v1', 'n-cds-1'], [XDS_EDS, 'v1', 'n-eds-1']
      )
    end
  end

  it 'NACKs a malformed resource and resolves once the management server corrects it' do
    start_management_server do
      configure_bootstrap
      @management.on(XDS_LDS, &ack_only_responder(XDS_LDS, listener_resource, version: 'v1', nonce: 'n-lds-1'))
      @management.on(XDS_RDS, &ack_only_responder(XDS_RDS, route_config_resource, version: 'v1', nonce: 'n-rds-1'))
      @management.on(XDS_EDS, &ack_only_responder(XDS_EDS, endpoint_resource(port: 21_002), version: 'v1', nonce: 'n-eds-1'))

      @management.on(XDS_CDS) do |req, _stream_index|
        if req.response_nonce.empty?
          # An Any whose value is not a valid Cluster -- every resource in
          # the response fails to parse, so the whole response is NACKed.
          bad = Google::Protobuf::Any.new(type_url: XDS_CDS, value: "\xFF\xFF\xFF".b)
          resp = XdsFakeManagementServer::Resp.new(version_info: 'v1', type_url: XDS_CDS, nonce: 'n-cds-bad', resources: [bad])
          [[resp], false]
        elsif !req.error_detail.nil?
          [[response_for(XDS_CDS, cluster_resource, version: 'v2', nonce: 'n-cds-2')], false]
        else
          [[], false]
        end
      end

      target = GRPC::Core::Transport.parse_target("xds:///#{XDS_LISTENER_NAME}")
      addresses = GRPC::Core::Transport.resolve_addresses(target)
      expect(addresses.map { |a| [a.host, a.port] }).to eq([['127.0.0.1', 21_002]])
      wait_until { @management.requests.any? { |r| r.type_url == XDS_CDS && r.response_nonce == 'n-cds-2' } }
      nack = @management.requests.find { |r| r.type_url == XDS_CDS && !r.error_detail.nil? }
      expect(nack).not_to be_nil
      expect(nack.response_nonce).to eq('n-cds-bad')
      # The malformed response's version was rejected, so the client's next
      # request still carries whatever version_info it had before -- none,
      # since this was the first CDS response ever seen.
      expect(nack.version_info).to eq('')
      expect(nack.error_detail.code).to eq(GRPC::Core::StatusCodes::INVALID_ARGUMENT)

      final_ack = @management.requests.find { |r| r.type_url == XDS_CDS && r.response_nonce == 'n-cds-2' }
      expect(final_ack.version_info).to eq('v2')
      expect(final_ack.error_detail).to be_nil
    end
  end

  it 're-subscribes to every resource, with the last accepted version and a fresh nonce, after the stream drops' do
    start_management_server do
      configure_bootstrap
      @management.on(XDS_LDS, &ack_only_responder(XDS_LDS, listener_resource, version: 'v1', nonce: 'n-lds-1'))
      @management.on(XDS_RDS, &ack_only_responder(XDS_RDS, route_config_resource, version: 'v1', nonce: 'n-rds-1'))
      @management.on(XDS_CDS, &ack_only_responder(XDS_CDS, cluster_resource, version: 'v1', nonce: 'n-cds-1'))
      @management.on(XDS_EDS, &ack_only_responder(XDS_EDS, endpoint_resource(port: 21_003), version: 'v1', nonce: 'n-eds-1'))

      target = GRPC::Core::Transport.parse_target("xds:///#{XDS_LISTENER_NAME}")
      addresses = GRPC::Core::Transport.resolve_addresses(target)
      expect(addresses.map { |a| [a.host, a.port] }).to eq([['127.0.0.1', 21_003]])

      drop_management_connection

      wait_until(timeout: 15) { @management.stream_count >= 2 }
      expect(@management.stream_count).to be >= 2

      resubscriptions = @management.requests.select { |r| r.response_nonce.empty? }
                                            .group_by(&:type_url)
                                   .transform_values(&:last)
      expect(resubscriptions[XDS_LDS].version_info).to eq('v1')
      expect(resubscriptions[XDS_RDS].version_info).to eq('v1')
      expect(resubscriptions[XDS_CDS].version_info).to eq('v1')
      expect(resubscriptions[XDS_EDS].version_info).to eq('v1')
    end
  end

  it 'does not leak the ADS stream connection past a reconnect' do
    start_management_server do
      configure_bootstrap
      @management.on(XDS_LDS, &ack_only_responder(XDS_LDS, listener_resource, version: 'v1', nonce: 'n-lds-1'))
      @management.on(XDS_RDS, &ack_only_responder(XDS_RDS, route_config_resource, version: 'v1', nonce: 'n-rds-1'))
      @management.on(XDS_CDS, &ack_only_responder(XDS_CDS, cluster_resource, version: 'v1', nonce: 'n-cds-1'))
      @management.on(XDS_EDS, &ack_only_responder(XDS_EDS, endpoint_resource(port: 21_004), version: 'v1', nonce: 'n-eds-1'))

      target = GRPC::Core::Transport.parse_target("xds:///#{XDS_LISTENER_NAME}")
      GRPC::Core::Transport.resolve_addresses(target)
      # The baseline is "after one ADS stream has run and settled", not the
      # process-wide count, since one-time costs like the stdlib Timeout
      # thread only appear once, however many streams follow.
      sleep 0.1 # let the first stream's threads settle
      after_first_stream = Thread.list.size

      drop_management_connection
      wait_until(timeout: 15) { @management.stream_count >= 2 }
      # Each reconnect opens its own ClientStub for the ADS bidi stream; one
      # left unclosed keeps that channel's maintenance thread running
      # forever, so a second stream must not cost more than the first did,
      # once its predecessor has had time to close.
      wait_until(timeout: 2) { Thread.list.size <= after_first_stream }
      expect(Thread.list.size).to eq(after_first_stream)

      GRPC::Core::XdsClient.reset_for_testing!
      wait_until(timeout: 2) { Thread.list.size < after_first_stream }
      expect(Thread.list.size).to be < after_first_stream
    end
  end

  describe 'bootstrap errors' do
    it 'fails channel construction when neither bootstrap env var is set' do
      expect { GRPC::Core::Channel.new('xds:///svc', {}, :this_channel_is_insecure) }
        .to raise_error(GRPC::Core::XdsBootstrap::Error, /GRPC_XDS_BOOTSTRAP/)
    end

    it 'names GRPC_XDS_BOOTSTRAP when the file it points at does not exist' do
      ENV['GRPC_XDS_BOOTSTRAP'] = '/nonexistent/bootstrap.json'
      expect { GRPC::Core::Channel.new('xds:///svc', {}, :this_channel_is_insecure) }
        .to raise_error(GRPC::Core::XdsBootstrap::Error, /GRPC_XDS_BOOTSTRAP/)
    ensure
      ENV.delete('GRPC_XDS_BOOTSTRAP')
    end

    it 'rejects malformed inline bootstrap JSON' do
      ENV['GRPC_XDS_BOOTSTRAP_CONFIG'] = '{not json'
      expect { GRPC::Core::Channel.new('xds:///svc', {}, :this_channel_is_insecure) }
        .to raise_error(GRPC::Core::XdsBootstrap::Error, /not valid JSON/)
    end

    it 'rejects a bootstrap with no xds_servers' do
      ENV['GRPC_XDS_BOOTSTRAP_CONFIG'] = { 'node' => {} }.to_json
      expect { GRPC::Core::Channel.new('xds:///svc', {}, :this_channel_is_insecure) }
        .to raise_error(GRPC::Core::XdsBootstrap::Error, /xds_servers/)
    end
  end

  describe 'xDS federation (gRFC A47)' do
    it 'resolves an xds://authority/name target, and every resource its chain names under that ' \
       'same authority, through that authority\'s own management server' do
      start_management_server do
        federated_authority = 'other-authority.example.com'
        federated_management, federated_uri = start_extra_management_server

        configure_bootstrap(authorities: {
                              federated_authority => { 'xds_servers' => [{ 'server_uri' => federated_uri,
                                                                           'channel_creds' => [{ 'type' => 'insecure' }] }] }
                            })

        resolved_listener_name = "xdstp://#{federated_authority}/envoy.config.listener.v3.Listener/fed-service"
        # gRFC A47 routes a resource by its own name's authority, not by
        # whatever authority discovered it: an old-style (non-xdstp) RDS/
        # CDS/EDS name here would route to the top-level xds_servers, not
        # to this federated authority's own server, so the whole chain
        # stays under xdstp://<federated_authority>/... throughout.
        fed_route_name = "xdstp://#{federated_authority}/envoy.config.route.v3.RouteConfiguration/fed-route"
        fed_cluster_name = "xdstp://#{federated_authority}/envoy.config.cluster.v3.Cluster/fed-cluster"
        federated_management.on(
          XDS_LDS, &ack_only_responder(XDS_LDS, listener_resource(name: resolved_listener_name,
                                                                  route_config_name: fed_route_name),
                                       version: 'v1', nonce: 'n-lds-1')
        )
        federated_management.on(
          XDS_RDS, &ack_only_responder(XDS_RDS, route_config_resource(name: fed_route_name, cluster_name: fed_cluster_name),
                                       version: 'v1', nonce: 'n-rds-1')
        )
        federated_management.on(
          XDS_CDS, &ack_only_responder(XDS_CDS, cluster_resource(name: fed_cluster_name),
                                       version: 'v1', nonce: 'n-cds-1')
        )
        federated_management.on(
          XDS_EDS, &ack_only_responder(XDS_EDS, endpoint_resource(name: fed_cluster_name, port: 21_005),
                                       version: 'v1', nonce: 'n-eds-1')
        )

        target = GRPC::Core::Transport.parse_target("xds://#{federated_authority}/fed-service")
        addresses = GRPC::Core::Transport.resolve_addresses(target)

        expect(addresses.map { |a| [a.host, a.port] }).to eq([['127.0.0.1', 21_005]])
        wait_until { federated_management.requests.count { |r| !r.response_nonce.empty? } >= 4 }
        # The top-level (unfederated) management server -- the one @host
        # points at -- never saw any of this: the whole chain went to the
        # authority's own server instead.
        expect(@management.requests).to be_empty
      end
    end

    it 'routes a Cluster/EDS named under a different authority than the Listener that references it' do
      start_management_server do
        # A Listener served by authority "a" names, by full xdstp name, a
        # Cluster served by a completely different authority "b" -- the
        # scenario upstream's federation_test.py actually exercises.
        authority_a = 'authority-a.example.com'
        authority_b = 'authority-b.example.com'
        management_a, uri_a = start_extra_management_server
        management_b, uri_b = start_extra_management_server

        configure_bootstrap(authorities: {
                              authority_a => { 'xds_servers' => [{ 'server_uri' => uri_a, 'channel_creds' => [{ 'type' => 'insecure' }] }] },
                              authority_b => { 'xds_servers' => [{ 'server_uri' => uri_b, 'channel_creds' => [{ 'type' => 'insecure' }] }] }
                            })

        resolved_listener_name = "xdstp://#{authority_a}/envoy.config.listener.v3.Listener/cross-service"
        cross_route_name = "xdstp://#{authority_a}/envoy.config.route.v3.RouteConfiguration/cross-route"
        cross_cluster_name = "xdstp://#{authority_b}/envoy.config.cluster.v3.Cluster/cross-cluster"

        management_a.on(
          XDS_LDS, &ack_only_responder(XDS_LDS, listener_resource(name: resolved_listener_name,
                                                                  route_config_name: cross_route_name),
                                       version: 'v1', nonce: 'n-lds-1')
        )
        management_a.on(
          XDS_RDS, &ack_only_responder(XDS_RDS, route_config_resource(name: cross_route_name, cluster_name: cross_cluster_name),
                                       version: 'v1', nonce: 'n-rds-1')
        )
        management_b.on(
          XDS_CDS, &ack_only_responder(XDS_CDS, cluster_resource(name: cross_cluster_name),
                                       version: 'v1', nonce: 'n-cds-1')
        )
        management_b.on(
          XDS_EDS, &ack_only_responder(XDS_EDS, endpoint_resource(name: cross_cluster_name, port: 21_006),
                                       version: 'v1', nonce: 'n-eds-1')
        )

        target = GRPC::Core::Transport.parse_target("xds://#{authority_a}/cross-service")
        # Two real connections (one per authority) to establish before this
        # resolves, rather than the one every other test needs -- a wider
        # timeout than the client's own 10s default, not a different
        # resolution path, so the whole target-parsing/authority-routing
        # chain Transport.parse_target set up is still exactly what runs.
        addresses = GRPC::Core::XdsClient.instance.resolve_endpoints(target.path, authority: target.xds_authority, timeout: 30)

        expect(addresses.map { |a| [a.host, a.port] }).to eq([['127.0.0.1', 21_006]])
        wait_until { management_b.requests.count { |r| !r.response_nonce.empty? } >= 2 }
        # Each authority's server saw exactly its own two resource types --
        # LDS/RDS went to "a", CDS/EDS to "b" -- and nothing crossed over.
        expect(management_a.requests.map(&:type_url).uniq).to contain_exactly(XDS_LDS, XDS_RDS)
        expect(management_b.requests.map(&:type_url).uniq).to contain_exactly(XDS_CDS, XDS_EDS)
        expect(@management.requests).to be_empty
      end
    end

    it 'refuses an xds:// target whose authority the bootstrap does not define' do
      configure_bootstrap(server_uri: 'localhost:1')
      expect { GRPC::Core::Transport.parse_target('xds://undefined-authority/svc') }
        .to raise_error(ArgumentError, /authority "undefined-authority".*not defined/)
    end
  end
end
