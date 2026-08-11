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
require 'socket'

# Session#handle_goaway used to parse nothing and never tell its handler, so
# an inbound GOAWAY -- the peer's "stop opening new streams here" -- was
# invisible to Connection. A client kept dialing new RPCs onto a connection
# the server had already drained, and only found out once the socket itself
# closed underneath it. Stands in for a real Session the same way
# GoawayCountingSession does in connection_lifetime_spec.
class DrainCountingSession
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
      id
    end
  end
end

describe 'inbound GOAWAY handling' do
  include GRPC::Spec::Helpers

  let(:session) { DrainCountingSession.new }

  def build_connection(**opts)
    conn = GRPC::Core::Connection.new(
      StringIO.new, peer: 'test', client: true,
                    max_receive_message_length: 1 << 20, **opts)
    conn.instance_variable_set(:@session, session)
    conn
  end

  after(:each) { @conn&.close }

  it 'refuses a new stream once a GOAWAY has been received, while the connection stays open' do
    @conn = build_connection
    @conn.start
    in_flight = @conn.open_rpc # keeps the connection from draining shut immediately
    @conn.on_goaway(in_flight.id, 0x0)
    expect(@conn.alive?).to be(true)
    expect { @conn.open_rpc }.to raise_error(GRPC::Core::Connection::Closed)
  end

  it 'lets a stream at or below last_stream_id keep running' do
    @conn = build_connection
    @conn.start
    stream = @conn.open_rpc
    @conn.on_goaway(stream.id, 0x0)
    expect(@conn.active_rpcs).to eq(1)
    expect(stream.failure).to be_nil
    expect(@conn.alive?).to be(true)
  end

  it 'fails a stream above last_stream_id with UNAVAILABLE, safe to retry elsewhere' do
    @conn = build_connection
    @conn.start
    accepted = @conn.open_rpc # id 1: below the boundary the GOAWAY names
    ahead = @conn.open_rpc    # id 3: the peer never saw this one
    @conn.on_goaway(accepted.id, 0x0)

    expect(ahead.failure).to_not be_nil
    expect(ahead.failure.code).to eq(GRPC::Core::StatusCodes::UNAVAILABLE)
    expect(accepted.failure).to be_nil
    expect(@conn.active_rpcs).to eq(1)
  end

  it 'closes itself once every stream at or below last_stream_id has finished' do
    @conn = build_connection
    @conn.start
    stream = @conn.open_rpc
    @conn.on_goaway(stream.id, 0x0)
    expect(@conn.alive?).to be(true)

    @conn.forget(stream.id)
    expect(@conn.alive?).to be(false)
  end

  it 'closes immediately when a GOAWAY drains a connection with nothing in flight' do
    @conn = build_connection
    @conn.start
    @conn.on_goaway(0, 0x0)
    expect(@conn.alive?).to be(false)
  end

  # The live round trip: a real server GOAWAY (here triggered by
  # grpc.max_connection_age_ms, exactly as connection_lifetime_spec drives
  # it) has to actually reach the client's Connection through
  # Session#handle_goaway for any of the above to matter in practice.
  it 'drains a client connection end to end: the in-flight RPC finishes, ' \
     'a concurrent call is refused, and the next call reconnects transparently' do
    build_rpc_server(
      server_opts: { server_args: { 'grpc.max_connection_age_ms' => 20 } })
    service = EchoService.new
    release = Queue.new
    first_call = true
    first_call_mu = Mutex.new
    # Only the first ('slow') RPC blocks server side; later ones must
    # return immediately for the timing this test relies on to hold.
    service.on_call_started = lambda do |_call|
      first = first_call_mu.synchronize do
        was_first = first_call
        first_call = false
        was_first
      end
      release.pop if first
    end
    run_services_on_server(@server, services: [service]) do
      stub = build_insecure_stub(EchoStub)

      slow = Thread.new { stub.an_rpc(EchoMsg.new(msg: 'slow')) }
      # Give max_connection_age time to fire and the client time to absorb
      # the GOAWAY while 'slow' is still blocked server side.
      sleep 0.15

      refused = begin
        stub.an_rpc(EchoMsg.new(msg: 'refused'))
        nil
      rescue GRPC::BadStatus => e
        e
      end
      expect(refused&.code).to eq(GRPC::Core::StatusCodes::UNAVAILABLE)

      release << :go
      expect(slow.value.msg).to eq('slow')

      # The drained connection closes once 'slow' finishes; give the
      # channel a moment to notice before asking for a fresh one.
      sleep 0.1
      expect(stub.an_rpc(EchoMsg.new(msg: 'ok')).msg).to eq('ok')
    end
  end
end
