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

# A minimal ADS fake -- see xds_spec.rb's XdsFakeManagementServer for the
# fuller version this trims down from. This one only needs to ACK whatever
# it is handed once (no NACK/reconnect scenarios here), since the point of
# this file is the LRS stream CDS's lrs_server triggers, not ADS itself.
#
# Named distinctly from xds_spec.rb's fakes (XdsLrsFake* vs XdsFake*) since
# rspec loads every spec file into one process and top-level class names
# must stay unique across the whole suite.
class XdsLrsFakeAdsServer
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
  end

  # Registers +blk+, called as (request) -> [responses], for every
  # DiscoveryRequest naming +type_url+ whose response_nonce is empty (the
  # first request for that type); every later request for it gets no
  # response, since nothing here ever changes an already-accepted resource.
  def on(type_url, &blk)
    @mu.synchronize { @responders[type_url] = blk }
  end

  def stream_aggregated_resources(requests, _call)
    Enumerator.new do |y|
      requests.each do |req|
        @mu.synchronize { @requests << req }
        next unless req.response_nonce.empty?
        responder = @mu.synchronize { @responders[req.type_url] }
        next if responder.nil?
        responder.call(req).each { |resp| y << resp }
      end
    end
  end
end

# The Load Reporting Service fake. +first_response+, sent right after the
# first (stats-less) LoadStatsRequest on every stream, is the whole
# handshake this client needs: which clusters to report on the
# subscription this exercises, and how often.
class XdsLrsFakeServer
  include GRPC::GenericService
  self.marshal_class_method = :encode
  self.unmarshal_class_method = :decode
  self.service_name = 'envoy.service.load_stats.v3.LoadReportingService'

  Req = Envoy::Service::LoadStats::V3::LoadStatsRequest
  Resp = Envoy::Service::LoadStats::V3::LoadStatsResponse

  rpc :StreamLoadStats, stream(Req), stream(Resp)

  attr_reader :requests, :stream_count
  attr_accessor :first_response

  def initialize
    @mu = Mutex.new
    @requests = []
    @stream_count = 0
  end

  # Every LoadStatsRequest that actually carries a report, as opposed to
  # the stats-less identification every stream opens with.
  def reports
    @mu.synchronize { @requests.reject { |r| r.cluster_stats.empty? } }
  end

  def identifications
    @mu.synchronize { @requests.select { |r| r.cluster_stats.empty? } }
  end

  def stream_load_stats(requests, _call)
    @mu.synchronize { @stream_count += 1 }
    first = true
    Enumerator.new do |y|
      requests.each do |req|
        @mu.synchronize { @requests << req }
        next unless first
        first = false
        resp = @mu.synchronize { @first_response }
        y << resp unless resp.nil?
      end
    end
  end
end

XDS_LRS_LDS = GRPC::Core::XdsClient::TYPE_LISTENER
XDS_LRS_RDS = GRPC::Core::XdsClient::TYPE_ROUTE
XDS_LRS_CDS = GRPC::Core::XdsClient::TYPE_CLUSTER
XDS_LRS_EDS = GRPC::Core::XdsClient::TYPE_ENDPOINT

XDS_LRS_LISTENER_NAME = 'lrs-service'
XDS_LRS_ROUTE_NAME = 'lrs-route'
XDS_LRS_CLUSTER_NAME = 'lrs-cluster'

describe 'xds LRS load reporting' do
  include GRPC::Spec::Helpers

  def any_for(type_url, message)
    Google::Protobuf::Any.new(type_url: type_url, value: message.class.encode(message))
  end

  def response_for(type_url, message, version:, nonce:)
    XdsLrsFakeAdsServer::Resp.new(version_info: version, type_url: type_url, nonce: nonce,
                                  resources: [any_for(type_url, message)])
  end

  def ack_only_responder(type_url, resource, version:, nonce:)
    ->(_req) { [response_for(type_url, resource, version: version, nonce: nonce)] }
  end

  def listener_resource
    hcm = Envoy::Extensions::Filters::Network::HttpConnectionManager::V3::HttpConnectionManager.new(
      rds: Envoy::Extensions::Filters::Network::HttpConnectionManager::V3::Rds.new(
        route_config_name: XDS_LRS_ROUTE_NAME
      )
    )
    Envoy::Config::Listener::V3::Listener.new(
      name: XDS_LRS_LISTENER_NAME,
      api_listener: Envoy::Config::Listener::V3::ApiListener.new(
        api_listener: any_for(
          'type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager',
          hcm
        )
      )
    )
  end

  def route_config_resource
    Envoy::Config::Route::V3::RouteConfiguration.new(
      name: XDS_LRS_ROUTE_NAME,
      virtual_hosts: [
        Envoy::Config::Route::V3::VirtualHost.new(
          name: 'vh', domains: ['*'],
          routes: [
            Envoy::Config::Route::V3::Route.new(
              match: Envoy::Config::Route::V3::RouteMatch.new(prefix: '/'),
              route: Envoy::Config::Route::V3::RouteAction.new(cluster: XDS_LRS_CLUSTER_NAME)
            )
          ]
        )
      ]
    )
  end

  # The one thing this fixture adds over an ordinary CDS Cluster: lrs_server
  # pointing at "self" -- the field that actually asks the client to report
  # this cluster's load back to the same management server.
  def cluster_resource
    Envoy::Config::Cluster::V3::Cluster.new(
      name: XDS_LRS_CLUSTER_NAME, type: :EDS,
      eds_cluster_config: Envoy::Config::Cluster::V3::Cluster::EdsClusterConfig.new(
        service_name: XDS_LRS_CLUSTER_NAME
      ),
      lrs_server: Envoy::Config::Core::V3::ConfigSource.new(
        self: Envoy::Config::Core::V3::SelfConfigSource.new
      )
    )
  end

  def endpoint_resource(host:, port:)
    Envoy::Config::Endpoint::V3::ClusterLoadAssignment.new(
      cluster_name: XDS_LRS_CLUSTER_NAME,
      endpoints: [
        Envoy::Config::Endpoint::V3::LocalityLbEndpoints.new(
          lb_endpoints: [
            Envoy::Config::Endpoint::V3::LbEndpoint.new(
              health_status: :HEALTHY,
              endpoint: Envoy::Config::Endpoint::V3::Endpoint.new(
                address: Envoy::Config::Core::V3::Address.new(
                  socket_address: Envoy::Config::Core::V3::SocketAddress.new(address: host, port_value: port)
                )
              )
            )
          ]
        )
      ]
    )
  end

  # +interval_seconds+ is generous (a full second) on purpose: every window
  # boundary this file asserts across is driven by real wall-clock time
  # (the same AdsConnection#pump_lrs_requests timer a real deployment
  # would hit), and the batches of calls straddling each window are plain
  # synchronous local RPCs that finish in milliseconds -- a one-second
  # window leaves ample room for them to land inside it without racing the
  # next report.
  def start_lrs(interval_seconds: 1.0)
    @lrs_interval_seconds = interval_seconds
    spawn_lrs_server(port: 0)
    ENV['GRPC_XDS_BOOTSTRAP_CONFIG'] = {
      'xds_servers' => [{ 'server_uri' => @mgmt_host, 'channel_creds' => [{ 'type' => 'insecure' }] }],
      'node' => { 'id' => 'xds-lrs-spec-node' }
    }.to_json
  end

  # Binds to +port+ (0 for "pick one") rather than always picking a fresh
  # port, so the reconnect test below can rebind on the exact port the
  # bootstrap already names -- the client's existing AdsConnection has no
  # way to learn of a *different* port, only to retry the one it has.
  def spawn_lrs_server(port:)
    @ads = XdsLrsFakeAdsServer.new
    @lrs = XdsLrsFakeServer.new
    @mgmt_server = GRPC::RpcServer.new(poll_period: 1)
    actual_port = @mgmt_server.add_http2_port("0.0.0.0:#{port}", :this_port_is_insecure)
    @mgmt_server.handle(@ads)
    @mgmt_server.handle(@lrs)
    @mgmt_thread = Thread.new { @mgmt_server.run }
    @mgmt_server.wait_till_running
    @mgmt_host = "0.0.0.0:#{actual_port}"
    interval_seconds = @lrs_interval_seconds
    @lrs.first_response = XdsLrsFakeServer::Resp.new(
      clusters: [XDS_LRS_CLUSTER_NAME],
      load_reporting_interval: Google::Protobuf::Duration.new(seconds: interval_seconds.to_i,
                                                              nanos: ((interval_seconds % 1) * 1e9).round)
    )
    @ads.on(XDS_LRS_LDS, &ack_only_responder(XDS_LRS_LDS, listener_resource, version: 'v1', nonce: 'n-lds-1'))
    @ads.on(XDS_LRS_RDS, &ack_only_responder(XDS_LRS_RDS, route_config_resource, version: 'v1', nonce: 'n-rds-1'))
    @ads.on(XDS_LRS_CDS, &ack_only_responder(XDS_LRS_CDS, cluster_resource, version: 'v1', nonce: 'n-cds-1'))
    @ads.on(XDS_LRS_EDS,
            &ack_only_responder(XDS_LRS_EDS, endpoint_resource(host: '127.0.0.1', port: @backend_port),
                                version: 'v1', nonce: 'n-eds-1'))
    actual_port
  end

  def stop_lrs
    return if @mgmt_server.nil?
    @mgmt_server.stop
    @mgmt_thread.join(5)
    @mgmt_server = nil
  end

  def wait_until(timeout: 5)
    deadline = GRPC::Core::RpcStream.now + timeout
    sleep(0.02) until yield || GRPC::Core::RpcStream.now >= deadline
  end

  # ClusterStats.upstream_locality_stats.first -- this client always
  # reports exactly one (unlocalized) entry per cluster; see
  # AdsConnection#cluster_stats_for_locked.
  def stats_for(report, cluster_name = XDS_LRS_CLUSTER_NAME)
    report.cluster_stats.find { |cs| cs.cluster_name == cluster_name }.upstream_locality_stats.first
  end

  before(:each) do
    GRPC::Core::XdsClient.reset_for_testing!
    build_rpc_server
    @backend_port = @port
  end

  after(:each) do
    GRPC::Core::XdsClient.reset_for_testing!
    stop_lrs
    ENV.delete('GRPC_XDS_BOOTSTRAP_CONFIG')
    ENV.delete('GRPC_XDS_BOOTSTRAP')
  end

  it 'reports per-cluster issued/successful/failed counts, resetting between reports' do
    start_lrs
    run_services_on_server(@server, services: [EchoService]) do
      stub = build_insecure_stub(EchoStub, host: "xds:///#{XDS_LRS_LISTENER_NAME}")

      # Two successes and one failure (an RPC EchoService declares but
      # never implements, so the server answers UNIMPLEMENTED), all
      # synchronous and therefore long finished before the next
      # assertion's wait_until even starts polling.
      stub.an_rpc(EchoMsg.new(msg: 'a'))
      stub.an_rpc(EchoMsg.new(msg: 'b'))
      expect { stub.a_client_streaming_rpc_unimplemented([EchoMsg.new]) }.to raise_error(GRPC::BadStatus)

      wait_until(timeout: 5) { @lrs.reports.size >= 1 }
      first_report = stats_for(@lrs.reports.first)
      expect(first_report.total_issued_requests).to eq(3)
      expect(first_report.total_successful_requests).to eq(2)
      expect(first_report.total_error_requests).to eq(1)
      expect(first_report.total_requests_in_progress).to eq(0)

      # One more success, in the next window: if the first report's
      # counts were not reset, this would show issued: 4, not 1.
      stub.an_rpc(EchoMsg.new(msg: 'c'))
      wait_until(timeout: 5) { @lrs.reports.size >= 2 }
      second_report = stats_for(@lrs.reports[1])
      expect(second_report.total_issued_requests).to eq(1)
      expect(second_report.total_successful_requests).to eq(1)
      expect(second_report.total_error_requests).to eq(0)
    end
  end

  it 'reports in_progress as a live gauge that does not reset between reports' do
    start_lrs
    run_services_on_server(@server, services: [EchoService]) do
      stub = build_insecure_stub(EchoStub, host: "xds:///#{XDS_LRS_LISTENER_NAME}")

      # A client-streaming call the test controls the end of: it stays
      # "in progress" (issued but not yet finished) until #close is
      # called on the request enumerator's queue below.
      requests = Queue.new
      held_call = Thread.new do
        stub.a_client_streaming_rpc(Enumerator.new do |y|
          loop do
            msg = requests.pop
            break if msg.nil?
            y << msg
          end
        end)
      end

      wait_until(timeout: 5) { @lrs.reports.size >= 1 }
      report_while_open = stats_for(@lrs.reports.first)
      expect(report_while_open.total_issued_requests).to eq(1)
      expect(report_while_open.total_requests_in_progress).to eq(1)

      requests.push(nil) # let the server finish the call
      held_call.join(5)

      wait_until(timeout: 5) { @lrs.reports.size >= 2 }
      report_after_close = stats_for(@lrs.reports[1])
      # in_progress is a gauge, not an interval delta -- it drops to 0
      # once the call actually finishes, in whichever report follows
      # that, without needing to be explicitly reset the way
      # issued/successful/failed are.
      expect(report_after_close.total_requests_in_progress).to eq(0)
      expect(report_after_close.total_successful_requests).to eq(1)
    end
  end

  it 'reconnects the LRS stream and resumes reporting from a fresh handshake' do
    start_lrs
    run_services_on_server(@server, services: [EchoService]) do
      stub = build_insecure_stub(EchoStub, host: "xds:///#{XDS_LRS_LISTENER_NAME}")
      stub.an_rpc(EchoMsg.new(msg: 'before'))
      wait_until(timeout: 5) { @lrs.reports.size >= 1 }

      # A clean app-level end of the response stream leaves the
      # underlying HTTP/2 connection half-open, so this drops the actual
      # socket the same way xds_spec.rb's #drop_management_connection
      # does: stop the listening server and rebind on the same port --
      # the bootstrap already in the environment names this port, and
      # nothing here changes it.
      port = @mgmt_host.split(':').last.to_i
      stop_lrs
      spawn_lrs_server(port: port)

      wait_until(timeout: 15) { @lrs.stream_count >= 1 }
      expect(@lrs.stream_count).to be >= 1
      # The fresh stream re-ran the stats-less identification -- LRS's
      # handshake does not survive a reconnect any more than ADS's nonces
      # do.
      expect(@lrs.identifications.size).to be >= 1

      stub.an_rpc(EchoMsg.new(msg: 'after'))
      wait_until(timeout: 5) { @lrs.reports.size >= 1 }
      resumed_report = stats_for(@lrs.reports.first)
      expect(resumed_report.total_issued_requests).to eq(1)
      expect(resumed_report.total_successful_requests).to eq(1)
    end
  end
end
