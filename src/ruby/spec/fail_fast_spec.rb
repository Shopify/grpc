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
require 'json'
require 'socket'

# C-core semantics for an RPC without wait_for_ready: while the channel is in
# TRANSIENT_FAILURE every pick fails at once, and a service config timeout
# caps the caller's own deadline rather than giving way to it. An RPC whose
# method config sets waitForReady waits instead, until it connects or its
# deadline passes.
describe 'fail-fast picks and service config timeouts' do
  include GRPC::Spec::Helpers

  noop = proc { |x| x }

  def elapsed
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
  end

  def stub_for(target, timeout: nil, max_attempts: 3)
    method_config = {
      name: [{}],
      retryPolicy: { maxAttempts: max_attempts, initialBackoff: '0.1s', maxBackoff: '1s',
                     backoffMultiplier: 1.5, retryableStatusCodes: ['UNAVAILABLE'] }
    }
    method_config[:timeout] = timeout if timeout
    args = { 'grpc.enable_retries' => 1,
             'grpc.service_config' => JSON.generate(methodConfig: [method_config]) }
    GRPC::ClientStub.new(target, :this_channel_is_insecure, channel_args: args)
  end

  def wait_for_ready_stub(target)
    args = { 'grpc.service_config' => JSON.generate(methodConfig: [{ name: [{}], waitForReady: true }]),
             'grpc.initial_reconnect_backoff_ms' => 100,
             'grpc.min_reconnect_backoff_ms' => 100,
             'grpc.max_reconnect_backoff_ms' => 200 }
    EchoStub.new(target, :this_channel_is_insecure, channel_args: args)
  end

  def unused_port
    reserved = TCPServer.new('127.0.0.1', 0)
    reserved.addr[1]
  ensure
    reserved&.close
  end

  it 'fails every RPC and retry fast while the channel cannot connect' do
    closed = TCPServer.new('127.0.0.1', 0)
    port = closed.addr[1]
    closed.close
    stub = stub_for("127.0.0.1:#{port}", max_attempts: 5)
    3.times do
      took = elapsed do
        expect do
          stub.request_response('/x.Y/Z', 'hi', noop, noop, deadline: Time.now + 30)
        end.to raise_error(GRPC::Unavailable)
      end
      expect(took).to be < 5
    end
  end

  it 'fails at once when the peer hangs up before its SETTINGS' do
    hangup = TCPServer.new('127.0.0.1', 0)
    acceptor = Thread.new do
      loop do
        client = hangup.accept
        begin
          client.readpartial(64)
        rescue StandardError
          nil
        end
        client.close
      end
    end
    stub = stub_for("127.0.0.1:#{hangup.addr[1]}")
    took = elapsed do
      expect do
        stub.request_response('/x.Y/Z', 'hi', noop, noop, deadline: Time.now + 30)
      end.to raise_error(GRPC::Unavailable)
    end
    expect(took).to be < 5
  ensure
    acceptor&.kill
    hangup&.close
  end

  it 'caps an explicit deadline with the service config timeout' do
    silent = TCPServer.new('127.0.0.1', 0)
    held = []
    acceptor = Thread.new { loop { held << silent.accept } }
    stub = stub_for("127.0.0.1:#{silent.addr[1]}", timeout: '1s')
    took = elapsed do
      expect do
        stub.request_response('/x.Y/Z', 'hi', noop, noop, deadline: Time.now + 3600)
      end.to raise_error(GRPC::DeadlineExceeded)
    end
    expect(took).to be < 5
  ensure
    acceptor&.kill
    held&.each(&:close)
    silent&.close
  end

  it 'lets an RPC with waitForReady wait until the channel connects' do
    port = unused_port
    stub = wait_for_ready_stub("127.0.0.1:#{port}")
    rpc = Thread.new { stub.an_rpc(EchoMsg.new(msg: 'waited'), deadline: Time.now + 15) }
    # Let the first connect fail, so that the channel is in TRANSIENT_FAILURE.
    sleep 0.5
    server = new_rpc_server_for_testing(poll_period: 1)
    server.add_http2_port("127.0.0.1:#{port}", :this_port_is_insecure)
    server.handle(EchoService)
    server_thread = Thread.new { server.run }
    expect(rpc.value.msg).to eq('waited')
  ensure
    server&.stop
    server_thread&.join
  end

  it 'gives an RPC with waitForReady DEADLINE_EXCEEDED when the channel never connects' do
    stub = wait_for_ready_stub("127.0.0.1:#{unused_port}")
    took = elapsed do
      expect { stub.an_rpc(EchoMsg.new, deadline: Time.now + 1) }.to raise_error(GRPC::DeadlineExceeded)
    end
    expect(took).to be >= 0.9
  end

  it 'lets an RPC with waitForReady and no deadline outlive the connect cap' do
    # Resolution takes longer than the cap, so the channel is still
    # CONNECTING, with no connect error, when the cap runs out.
    stub_const('GRPC::Core::Transport::DEFAULT_CONNECT_TIMEOUT', 0.3)
    server = new_rpc_server_for_testing(poll_period: 1)
    port = server.add_http2_port('127.0.0.1:0', :this_port_is_insecure)
    server.handle(EchoService)
    server_thread = Thread.new { server.run }
    server.wait_till_running
    allow(GRPC::Core::Transport).to receive(:resolve_addresses) do |target|
      sleep 1
      target.addresses = [GRPC::Core::Transport::Target.new(:tcp, '127.0.0.1', port, nil)]
    end
    stub = wait_for_ready_stub('slow-dns.example:443')
    expect(stub.an_rpc(EchoMsg.new(msg: 'resolved')).msg).to eq('resolved')
  ensure
    server&.stop
    server_thread&.join
  end
end
