# frozen_string_literal: true

# Copyright 2025 gRPC authors.
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

# grpc.max_connection_idle_ms, grpc.max_connection_age_ms (with its grace
# period) and grpc.client_idle_timeout_ms were accepted and never acted on:
# a server never reclaimed a connection nobody was using, and never rotated
# one out from under a long-lived client. All four share the connection's
# existing maintenance timer (the same thread that drives keepalive), so
# this adds no new per-connection thread.
class GoawayCountingSession
  attr_reader :goaways

  def initialize
    @goaways = 0
    @next_stream_id = 1
    @mu = Mutex.new
  end

  def send_goaway(_error_code = 0x0)
    @mu.synchronize { @goaways += 1 }
  end

  def connect; end
  def receive; end
  def shutdown; end

  def new_stream
    @mu.synchronize do
      id = @next_stream_id
      @next_stream_id += 2
      id
    end
  end
end

describe 'connection lifetime limits' do
  include GRPC::Spec::Helpers

  def build_connection(client: false, **opts)
    conn = GRPC::Core::Connection.new(
      StringIO.new, peer: 'test', client: client,
                    max_receive_message_length: 1 << 20, **opts)
    conn.instance_variable_set(:@session, session)
    conn
  end

  # Simulates an inbound HEADERS block starting a new RPC, the same way the
  # session's reader thread would call it through #on_headers.
  def fake_headers(id)
    Struct.new(:id, :headers).new(id, [[':path', '/pkg.Svc/Method']])
  end

  let(:session) { GoawayCountingSession.new }

  after(:each) do
    @conn&.close
  end

  describe 'grpc.max_connection_idle_ms' do
    it 'closes a server connection that sits idle past the limit' do
      @conn = build_connection(max_connection_idle: 0.02)
      @conn.start
      sleep 0.08
      expect(@conn.alive?).to be(false)
    end

    it 'does not close while an RPC is in flight, however long it runs' do
      @conn = build_connection(max_connection_idle: 0.02)
      @conn.start
      @conn.open_rpc
      sleep 0.08
      expect(@conn.alive?).to be(true)
    end

    it 'restarts the idle clock once the last RPC finishes' do
      @conn = build_connection(max_connection_idle: 0.03)
      @conn.start
      stream = @conn.open_rpc
      sleep 0.05
      @conn.forget(stream.id)
      # Still alive right after the RPC ends: the idle period only just
      # started, even though the connection itself is older than the limit.
      expect(@conn.alive?).to be(true)
      sleep 0.08
      expect(@conn.alive?).to be(false)
    end
  end

  describe 'grpc.client_idle_timeout_ms' do
    it 'closes an idle client connection, returning it to the caller as dead' do
      @conn = build_connection(client: true, client_idle_timeout: 0.02)
      @conn.start
      sleep 0.08
      expect(@conn.alive?).to be(false)
    end

    it 'does not fire on a server connection, even with the same idle gap' do
      @conn = build_connection(client: false, client_idle_timeout: 0.02)
      @conn.start
      sleep 0.08
      expect(@conn.alive?).to be(true)
    end
  end

  describe 'grpc.max_connection_age_ms' do
    it 'sends exactly one GOAWAY once the connection outlives the limit' do
      @conn = build_connection(max_connection_age: 0.02)
      @conn.start
      sleep 0.08
      expect(session.goaways).to eq(1)
    end

    it 'never sends GOAWAY before the limit elapses' do
      @conn = build_connection(max_connection_age: 1.0)
      @conn.start
      sleep 0.05
      expect(session.goaways).to eq(0)
    end

    it 'does not cut an in-flight RPC the instant GOAWAY goes out' do
      @conn = build_connection(max_connection_age: 0.02, max_connection_age_grace: 1.0)
      @conn.start
      @conn.open_rpc
      sleep 0.08
      expect(@conn.alive?).to be(true)
      expect(session.goaways).to eq(1)
    end

    it 'closes once the last RPC drains after GOAWAY, without waiting for the grace deadline' do
      @conn = build_connection(max_connection_age: 0.02, max_connection_age_grace: 1.0)
      @conn.start
      stream = @conn.open_rpc
      sleep 0.05
      @conn.forget(stream.id)
      sleep 0.03
      expect(@conn.alive?).to be(false)
    end

    it 'closes once the connection is old enough, with no RPC ever having run' do
      @conn = build_connection(max_connection_age: 0.02)
      @conn.start
      sleep 0.08
      expect(@conn.alive?).to be(false)
    end

    it 'refuses new streams once GOAWAY has gone out, even while still draining' do
      @conn = build_connection(max_connection_age: 0.02, max_connection_age_grace: 1.0)
      @conn.start
      @conn.open_rpc
      sleep 0.05
      @conn.on_headers(fake_headers(99))
      expect(@conn.active_rpcs).to eq(1)
      expect(@conn.alive?).to be(true)
    end

    it 'does not wait forever for a drain when no grace period is configured' do
      # gRPC's own default grace is effectively infinite, but this
      # implementation only waits for one when the caller sets it -- an
      # unset grace must never force-close a still-running RPC.
      @conn = build_connection(max_connection_age: 0.02)
      @conn.start
      @conn.open_rpc
      sleep 0.08
      expect(@conn.alive?).to be(true)
    end
  end

  describe 'the grace period' do
    it 'force-closes the connection, failing the in-flight RPC, once grace expires' do
      @conn = build_connection(max_connection_age: 0.02, max_connection_age_grace: 0.03)
      nil
      @conn.start
      stream = @conn.open_rpc
      sleep 0.08
      expect(@conn.alive?).to be(false)
      expect(stream.failure).to_not be_nil
    end

    it 'does not force-close before the grace deadline, even though GOAWAY already went out' do
      @conn = build_connection(max_connection_age: 0.02, max_connection_age_grace: 0.2)
      @conn.start
      stream = @conn.open_rpc
      sleep 0.08
      expect(@conn.alive?).to be(true)
      expect(stream.failure).to be_nil
    end
  end

  it 'stops its timer thread when the connection closes' do
    before = Thread.list.size
    conn = build_connection(max_connection_idle: 0.02)
    conn.start
    sleep 0.05
    conn.close
    sleep 0.05
    expect(Thread.list.size).to be <= before
  end

  describe 'the channel arguments' do
    it 'accepts all four connection-lifetime arguments now that they work' do
      args = {
        'grpc.max_connection_idle_ms' => 1000,
        'grpc.max_connection_age_ms' => 2000,
        'grpc.max_connection_age_grace_ms' => 500,
        'grpc.client_idle_timeout_ms' => 3000
      }
      expect { GRPC::Core::ChannelArgs.normalize(args) }.to_not raise_error
    end

    it 'reads each as milliseconds converted to seconds' do
      expect(GRPC::Core::ChannelArgs.seconds(
               { 'grpc.max_connection_age_ms' => 1500 }, 'grpc.max_connection_age_ms'
             )).to eq(1.5)
    end
  end

  # A live round trip: the client channel notices its idle connection died,
  # drops to IDLE, and the next call reconnects rather than raising.
  it 'returns a channel to IDLE after a client idle timeout, and reconnects on the next call' do
    build_rpc_server
    run_services_on_server(@server, services: [EchoService]) do
      stub = build_insecure_stub(
        EchoStub,
        opts: { channel_args: { 'grpc.client_idle_timeout_ms' => 50 } })
      expect(stub.an_rpc(EchoMsg.new(msg: 'first')).msg).to eq('first')

      channel = stub.instance_variable_get(:@ch)
      deadline = GRPC::Core::RpcStream.now + 2
      sleep 0.02 while channel.connectivity_state != GRPC::Core::ConnectivityStates::IDLE &&
                       GRPC::Core::RpcStream.now < deadline
      expect(channel.connectivity_state).to eq(GRPC::Core::ConnectivityStates::IDLE)

      expect(stub.an_rpc(EchoMsg.new(msg: 'second')).msg).to eq('second')
    end
  end

  # A live round trip for the server side: max_connection_age sends GOAWAY
  # under an RPC that is still running, and the RPC still gets its response
  # because the grace period comfortably outlasts it.
  it 'lets an in-flight RPC finish after the server sends GOAWAY for max age' do
    build_rpc_server(
      server_opts: {
        server_args: {
          'grpc.max_connection_age_ms' => 20,
          'grpc.max_connection_age_grace_ms' => 1000
        }
      })
    service = EchoService.new
    service.on_call_started = proc { sleep 0.05 }
    run_services_on_server(@server, services: [service]) do
      stub = build_insecure_stub(EchoStub)
      expect(stub.an_rpc(EchoMsg.new(msg: 'ok')).msg).to eq('ok')
    end
  end
end
