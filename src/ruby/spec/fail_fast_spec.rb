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
# caps the caller's own deadline rather than giving way to it.
describe 'fail-fast picks and service config timeouts' do
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
end
