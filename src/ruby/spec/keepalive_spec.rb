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

# Counts the PINGs a connection sends, without a peer having to answer.
class PingCountingSession
  attr_reader :pings

  def initialize
    @pings = 0
    @mu = Mutex.new
  end

  def ping
    @mu.synchronize { @pings += 1 }
  end

  # Connection#note_data_sent_since_last_ping polls this every tick; a
  # constant 0 means "no real RPC traffic ever flows" for these fakes,
  # which is exactly what they simulate.
  def data_frames_sent
    0
  end

  def connect; end

  def receive; end

  def shutdown; end

  def new_stream
    1
  end
end

# grpc.keepalive_time_ms was accepted and never acted on, so a connection
# behind a firewall that drops idle flows died with no explanation. The PING
# runs on a timer rather than on the last byte seen, so it costs one thread
# per connection and nothing per message.
describe 'keepalive' do
  include GRPC::Spec::Helpers

  let(:session) { PingCountingSession.new }

  def build_connection(**opts)
    conn = GRPC::Core::Connection.new(
      StringIO.new, peer: 'test', client: true,
                    max_receive_message_length: 1 << 20, **opts)
    conn.instance_variable_set(:@session, session)
    conn
  end

  after(:each) do
    @conn&.close
  end

  it 'sends no ping when keepalive is not configured' do
    @conn = build_connection
    @conn.start
    sleep 0.15
    expect(session.pings).to eq(0)
  end

  it 'pings on the configured interval once a stream is open' do
    @conn = build_connection(keepalive_time: 0.02,
                             keepalive_permit_without_calls: true)
    @conn.start
    sleep 0.15
    expect(session.pings).to be > 1
  end

  # A ping with no RPC in flight is what upsets strict peers, so gRPC only
  # sends one when the caller opted in.
  it 'stays quiet on an idle connection unless permitted' do
    @conn = build_connection(keepalive_time: 0.02,
                             keepalive_permit_without_calls: false)
    @conn.start
    sleep 0.15
    expect(session.pings).to eq(0)
  end

  it 'pings without the opt-in once an RPC is in flight' do
    @conn = build_connection(keepalive_time: 0.02,
                             keepalive_permit_without_calls: false)
    @conn.start
    @conn.open_rpc
    sleep 0.15
    expect(session.pings).to be > 0
  end

  it 'closes the connection when no ack arrives in time' do
    @conn = build_connection(keepalive_time: 0.02, keepalive_timeout: 0.03,
                             keepalive_permit_without_calls: true)
    @conn.start
    sleep 0.3
    expect(@conn.alive?).to be(false)
  end

  it 'stays open while the peer acknowledges' do
    @conn = build_connection(keepalive_time: 0.02, keepalive_timeout: 0.05,
                             keepalive_permit_without_calls: true)
    @conn.start
    6.times do
      sleep 0.03
      @conn.on_ping(1000)
    end
    expect(@conn.alive?).to be(true)
  end

  it 'stops its timer thread when the connection closes' do
    before = Thread.list.size
    conn = build_connection(keepalive_time: 0.02,
                            keepalive_permit_without_calls: true)
    conn.start
    sleep 0.05
    conn.close
    sleep 0.05
    expect(Thread.list.size).to be <= before
  end

  describe 'the channel arguments' do
    it 'accepts the keepalive arguments now that they work' do
      args = {
        'grpc.keepalive_time_ms' => 1000,
        'grpc.keepalive_timeout_ms' => 500,
        'grpc.keepalive_permit_without_calls' => 1
      }
      expect { GRPC::Core::ChannelArgs.normalize(args) }.to_not raise_error
    end

    it 'reads milliseconds as seconds' do
      expect(GRPC::Core::ChannelArgs.seconds(
               { 'grpc.keepalive_time_ms' => 2500 }, 'grpc.keepalive_time_ms'
             )).to eq(2.5)
    end

    it 'treats a non-positive interval as unset, as gRPC does' do
      expect(GRPC::Core::ChannelArgs.seconds(
               { 'grpc.keepalive_time_ms' => 0 }, 'grpc.keepalive_time_ms'
             )).to be_nil
    end

    it 'carries the setting into a live channel' do
      build_rpc_server
      run_services_on_server(@server, services: [EchoService]) do
        stub = build_insecure_stub(
          EchoStub,
          opts: { channel_args: { 'grpc.keepalive_time_ms' => 60_000 } })
        expect(stub.an_rpc(EchoMsg.new(msg: 'ok')).msg).to eq('ok')
      end
    end
  end
end
