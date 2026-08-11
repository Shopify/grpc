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
require 'stringio'
require 'grpc/health/v1/health_services_pb'
require 'json'

# grpc/health/checker.rb -- the Grpc::Health::Checker this gem ships --
# implements only Check, never Watch, and this spec does not change that
# (upstream Ruby's shipped checker has never implemented Watch either).
# HealthWatcher needs a peer that answers Watch to prove itself against, so
# this is a spec-only double, never shipped.
class WatchableHealthChecker < Grpc::Health::V1::Health::Service
  Status = Grpc::Health::V1::HealthCheckResponse::ServingStatus

  attr_reader :watch_calls

  def initialize
    super
    @statuses = {}
    @mu = Mutex.new
    @watch_calls = 0
  end

  def set_status(service, status)
    @mu.synchronize { @statuses[service] = status }
  end

  def check(req, _call)
    status = @mu.synchronize { @statuses[req.service] }
    return Grpc::Health::V1::HealthCheckResponse.new(status: status) unless status.nil?
    raise GRPC::BadStatus.new_status_exception(GRPC::Core::StatusCodes::NOT_FOUND)
  end

  # One response per call, ending the stream immediately, rather than
  # holding it open: every scenario below wants a status fixed for the
  # whole test, and a short-lived call is what lets the "re-established
  # after it drops" case observe #watch_calls climb on its own backoff.
  def watch(req, _call)
    @mu.synchronize { @watch_calls += 1 }
    status = @mu.synchronize { @statuses[req.service] } || Status::SERVICE_UNKNOWN
    [Grpc::Health::V1::HealthCheckResponse.new(status: status)]
  end
end

# Stands in for a real Http2::Kantan::H2::Session the same way
# DrainCountingSession does in goaway_spec.rb, so HealthWatcher can be
# driven against a Subchannel with no real socket: #send_headers/#send_data
# capture what HealthWatcher writes, and the spec pushes fabricated
# responses straight into the RpcStream #open_rpc hands back.
class FakeHealthSession
  attr_reader :streams_opened

  def initialize
    @next_stream_id = 1
    @streams_opened = 0
    @mu = Mutex.new
  end

  def connect; end
  def receive; end
  def shutdown; end

  # Connection#close asks the session whether its reader and writer threads
  # ever started, so it knows whether a queued shutdown will actually drain.
  # These fakes have no threads, so the socket path is the honest answer.
  def running?
    false
  end

  def new_stream
    @mu.synchronize do
      id = @next_stream_id
      @next_stream_id += 2
      @streams_opened += 1
      id
    end
  end

  def send_headers(_id, _pairs, has_body: true); end

  def send_data(_id, _frame, ack_to: nil, ack_size: 0, end_stream: false)
    _ = end_stream
    ack_to&.ack_write(ack_size)
  end

  def send_trailers(_id, _pairs); end
  def send_rst_stream(_id, _error_code); end
end

# own retry to happen quickly rather than at grpc.*_reconnect_backoff_ms's
# real-world default of a full second.
FAST_BACKOFF_ARGS = {
  'grpc.initial_reconnect_backoff_ms' => 20,
  'grpc.min_reconnect_backoff_ms' => 20,
  'grpc.max_reconnect_backoff_ms' => 40
}.freeze

describe 'client-side LB health checking (gRFC A17)' do
  include GRPC::Spec::Helpers

  def wait_until(timeout = 3.0)
    deadline = Time.now + timeout
    loop do
      return true if yield
      return false if Time.now > deadline
      sleep 0.01
    end
  end

  def health_check_service_config(service_name)
    { 'healthCheckConfig' => { 'serviceName' => service_name } }.to_json
  end

  # Backoff config shared by every scenario that needs the health watch's

  # ---- low-level: Subchannel + HealthWatcher against a fake session ------

  def health_check_frame(status)
    payload = Grpc::Health::V1::HealthCheckResponse.encode(
      Grpc::Health::V1::HealthCheckResponse.new(status: status))
    [0, payload.bytesize].pack('CN') + payload
  end

  # A Subchannel with health checking wired to a fake connection: #dial
  # returns a real GRPC::Core::Connection with its session swapped out, so
  # the real Subchannel/HealthWatcher code runs, but nothing touches a
  # socket.
  def build_health_subchannel(service_name: 'svc')
    session = FakeHealthSession.new
    dial = lambda do |_address, _on_close|
      connection = GRPC::Core::Connection.new(
        StringIO.new, peer: 'fake-health-peer', client: true,
                      max_receive_message_length: 1 << 20)
      connection.instance_variable_set(:@session, session)
      connection.start
      connection
    end
    GRPC::Core::Subchannel.new(
      :fake_address, dial: dial, health_check_service_name: service_name,
                     health_backoff_factory: -> { GRPC::Core::ReconnectBackoff.new(initial: 0.02, min: 0.02, max: 0.04) })
  end

  # The single RpcStream the health watcher has open on +connection+ right
  # now, once it has gotten around to opening one.
  def watch_stream_of(connection)
    stream = nil
    wait_until { stream = connection.instance_variable_get(:@streams).values.first }
    stream
  end

  after(:each) { @fake_subchannels&.each(&:close) }

  def track(subchannel)
    (@fake_subchannels ||= []) << subchannel
    subchannel
  end

  it 'keeps a subchannel alive by default until the watch says otherwise' do
    sc = track(build_health_subchannel)
    sc.maybe_connect
    expect(wait_until { sc.state == GRPC::Core::ConnectivityStates::READY }).to be(true)
    expect(sc.alive?).to be(true) # gRFC A17: healthy is the default
  end

  it 'stops being alive once the watch reports NOT_SERVING, though the transport stays READY' do
    sc = track(build_health_subchannel)
    sc.maybe_connect
    expect(wait_until { sc.state == GRPC::Core::ConnectivityStates::READY }).to be(true)
    stream = watch_stream_of(sc.connection)

    stream.push_data(health_check_frame(:NOT_SERVING))

    expect(wait_until { !sc.healthy? }).to be(true)
    expect(sc.alive?).to be(false)
    expect(sc.state).to eq(GRPC::Core::ConnectivityStates::READY) # the transport itself never moved
  end

  it 'is not picked by round_robin while another subchannel reports SERVING' do
    healthy = track(build_health_subchannel)
    unhealthy = track(build_health_subchannel)
    [healthy, unhealthy].each(&:maybe_connect)
    expect(wait_until do
      [healthy, unhealthy].all? { |sc| sc.state == GRPC::Core::ConnectivityStates::READY }
    end).to be(true)

    watch_stream_of(healthy.connection).push_data(health_check_frame(:SERVING))
    watch_stream_of(unhealthy.connection).push_data(health_check_frame(:NOT_SERVING))
    expect(wait_until { healthy.alive? && !unhealthy.alive? }).to be(true)

    policy = GRPC::Core::RoundRobinPolicy.new([healthy, unhealthy])
    expect(Array.new(6) { policy.pick }.uniq).to eq([healthy])
    expect(GRPC::Core::LbPolicyState.aggregate([healthy, unhealthy]))
      .to eq(GRPC::Core::ConnectivityStates::READY)
  end

  it 'is not READY, not TRANSIENT_FAILURE, once every subchannel is unhealthy' do
    a = track(build_health_subchannel)
    b = track(build_health_subchannel)
    [a, b].each(&:maybe_connect)
    expect(wait_until { [a, b].all? { |sc| sc.state == GRPC::Core::ConnectivityStates::READY } }).to be(true)

    watch_stream_of(a.connection).push_data(health_check_frame(:NOT_SERVING))
    watch_stream_of(b.connection).push_data(health_check_frame(:NOT_SERVING))
    expect(wait_until { [a, b].none?(&:healthy?) }).to be(true)

    expect(GRPC::Core::LbPolicyState.aggregate([a, b])).to eq(GRPC::Core::ConnectivityStates::IDLE)
  end

  it 'treats a backend that answers UNIMPLEMENTED for Watch as healthy, not silently dropped' do
    sc = track(build_health_subchannel)
    sc.maybe_connect
    expect(wait_until { sc.state == GRPC::Core::ConnectivityStates::READY }).to be(true)
    stream = watch_stream_of(sc.connection)

    stream.push_trailers([%w[grpc-status 12]]) # UNIMPLEMENTED: no health service on this peer
    stream.push_eos

    expect(wait_until { sc.alive? }).to be(true)
    session = sc.connection.instance_variable_get(:@session)
    opened_before = session.streams_opened
    sleep 0.1 # UNIMPLEMENTED must not be retried; a second Watch would show up here
    expect(session.streams_opened).to eq(opened_before)
    expect(sc.alive?).to be(true)
  end

  it 'retries with backoff and stays alive meanwhile when the watch stream drops' do
    sc = track(build_health_subchannel)
    sc.maybe_connect
    expect(wait_until { sc.state == GRPC::Core::ConnectivityStates::READY }).to be(true)
    first_stream = watch_stream_of(sc.connection)
    first_stream.push_data(health_check_frame(:NOT_SERVING))
    expect(wait_until { !sc.healthy? }).to be(true)

    first_stream.push_failure(GRPC::Core::StatusCodes::UNAVAILABLE, 'stream dropped')

    expect(wait_until { sc.healthy? }).to be(true) # fail open while no stream is open
    expect(wait_until do
      sc.connection.instance_variable_get(:@streams).values.any? { |s| !s.equal?(first_stream) }
    end).to be(true)
  end

  it 'stops the health watch thread when the subchannel closes' do
    sc = build_health_subchannel
    sc.maybe_connect
    expect(wait_until { sc.state == GRPC::Core::ConnectivityStates::READY }).to be(true)
    expect(wait_until { Thread.list.any? { |t| t.name == 'grpc-health' && t.alive? } }).to be(true)

    sc.close

    expect(wait_until { Thread.list.none? { |t| t.name == 'grpc-health' && t.alive? } }).to be(true)
  end

  # ---- end to end: a real Channel across real backends --------------------

  def build_backend(health_checker = nil)
    server = new_rpc_server_for_testing(poll_period: 1)
    port = server.add_http2_port('127.0.0.1:0', :this_port_is_insecure)
    mu = Mutex.new
    count = 0
    echo = EchoService.new
    echo.on_call_started = ->(_call) { mu.synchronize { count += 1 } }
    server.handle(echo)
    server.handle(health_checker) if health_checker
    thread = Thread.new { server.run }
    server.wait_till_running
    { server: server, thread: thread, port: port, count: -> { mu.synchronize { count } } }
  end

  def stop_backend(backend)
    backend[:server].stop
    backend[:thread].join
  end

  def target_for(backend)
    GRPC::Core::Transport::Target.new(:tcp, '127.0.0.1', backend[:port], nil)
  end

  def stub_addresses(*targets)
    allow(GRPC::Core::Transport).to receive(:resolve_addresses) do |target|
      target.addresses = targets
    end
  end

  it 'never sends a call to a live backend whose health check reports NOT_SERVING' do
    healthy_checker = WatchableHealthChecker.new
    healthy_checker.set_status('svc', :SERVING)
    unhealthy_checker = WatchableHealthChecker.new
    unhealthy_checker.set_status('svc', :NOT_SERVING)
    healthy = build_backend(healthy_checker)
    unhealthy = build_backend(unhealthy_checker)
    begin
      stub_addresses(target_for(healthy), target_for(unhealthy))
      channel_args = FAST_BACKOFF_ARGS.merge(
        'grpc.service_config' => health_check_service_config('svc'),
        'grpc.lb_policy_name' => 'round_robin')
      stub = build_insecure_stub(EchoStub, host: 'lb-health-pick.example:443',
                                           opts: { channel_args: channel_args })
      channel = stub.instance_variable_get(:@ch)

      stub.an_rpc(EchoMsg.new(msg: 'warm'), deadline: Time.now + 5)
      subchannels = nil
      expect(wait_until do
        subchannels = channel.instance_variable_get(:@subchannels)
        subchannels&.size == 2 && subchannels.count(&:alive?) == 1
      end).to be(true)
      expect(channel.connectivity_state).to eq(GRPC::Core::ConnectivityStates::READY)

      10.times { stub.an_rpc(EchoMsg.new(msg: 'rr'), deadline: Time.now + 5) }

      expect(unhealthy_checker.watch_calls).to be >= 1 # the health check actually ran
      expect(unhealthy[:count].call).to eq(0)
      expect(healthy[:count].call).to be >= 10
    ensure
      stop_backend(healthy)
      stop_backend(unhealthy)
    end
  end

  it 'still uses a live backend that has no health service at all' do
    backend = build_backend # no health checker registered: Watch is UNIMPLEMENTED there
    begin
      stub_addresses(target_for(backend))
      channel_args = FAST_BACKOFF_ARGS.merge('grpc.service_config' => health_check_service_config('svc'))
      stub = build_insecure_stub(EchoStub, host: 'lb-health-unimpl.example:443',
                                           opts: { channel_args: channel_args })

      reply = stub.an_rpc(EchoMsg.new(msg: 'still works'), deadline: Time.now + 5)

      expect(reply.msg).to eq('still works')
      expect(backend[:count].call).to eq(1)
    ensure
      stop_backend(backend)
    end
  end

  it 'grpc.inhibit_health_checking turns the whole feature off' do
    checker = WatchableHealthChecker.new
    checker.set_status('svc', :NOT_SERVING) # would make the backend unusable if honoured
    backend = build_backend(checker)
    begin
      stub_addresses(target_for(backend))
      channel_args = FAST_BACKOFF_ARGS.merge(
        'grpc.service_config' => health_check_service_config('svc'),
        'grpc.inhibit_health_checking' => 1)
      stub = build_insecure_stub(EchoStub, host: 'lb-health-inhibit.example:443',
                                           opts: { channel_args: channel_args })

      reply = stub.an_rpc(EchoMsg.new(msg: 'inhibited'), deadline: Time.now + 5)

      expect(reply.msg).to eq('inhibited')
      expect(checker.watch_calls).to eq(0) # never started at all, not merely ignored
    ensure
      stop_backend(backend)
    end
  end

  it 'stops every health watch thread when the channel closes' do
    checker = WatchableHealthChecker.new
    checker.set_status('svc', :SERVING)
    backend = build_backend(checker)
    begin
      stub_addresses(target_for(backend))
      channel_args = FAST_BACKOFF_ARGS.merge('grpc.service_config' => health_check_service_config('svc'))
      stub = build_insecure_stub(EchoStub, host: 'lb-health-close.example:443',
                                           opts: { channel_args: channel_args })
      channel = stub.instance_variable_get(:@ch)

      stub.an_rpc(EchoMsg.new(msg: 'warm'), deadline: Time.now + 5)
      expect(wait_until { Thread.list.any? { |t| t.name == 'grpc-health' && t.alive? } }).to be(true)

      channel.close

      expect(wait_until { Thread.list.none? { |t| t.name == 'grpc-health' && t.alive? } }).to be(true)
    ensure
      stop_backend(backend)
    end
  end
end
