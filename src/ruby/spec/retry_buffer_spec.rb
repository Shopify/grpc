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
require 'json'

# Four small, previously-missing pieces:
#
# * grpc.per_rpc_retry_buffer_size was never read, so a client-streaming
#   retry buffered every request a long-running call ever sent, for as long
#   as the call lived. This is the reason the argument exists in gRPC at
#   all.
# * grpc.absolute_max_metadata_size was rejected outright even though its
#   companion grpc.max_metadata_size was already enforced.
# * grpc.experimental.enable_hedging was never consulted, so a service
#   config's hedgingPolicy hedged unconditionally.
# * grpc.http_proxy / grpc.address_http_proxy were parsed nowhere: only the
#   environment could ever select a proxy.
#
# A client-streaming servicer that records every batch of requests it
# actually received and fails a fixed number of leading attempts, so a test
# can tell a retried attempt from a first (and only) one.
class RetryBufferService
  include GRPC::GenericService
  rpc :a_client_streaming_rpc, stream(EchoMsg), EchoMsg

  attr_reader :calls, :received_batches

  def initialize(fail_times: 0)
    @fail_times = fail_times
    @calls = 0
    @received_batches = []
    @mu = Mutex.new
  end

  def a_client_streaming_rpc(call)
    msgs = call.each_remote_read.map(&:msg)
    attempt = @mu.synchronize do
      @calls += 1
      @received_batches << msgs
      @calls
    end
    if attempt <= @fail_times
      raise GRPC::BadStatus.new_status_exception(
        GRPC::Core::StatusCodes::UNAVAILABLE, 'retry me')
    end
    EchoMsg.new(msg: msgs.join(','))
  end
end
RetryBufferStub = RetryBufferService.rpc_stub_class

# A unary servicer that fails its first attempt with a status hedging's
# nonFatalStatusCodes forgives, so an immediate second (hedged) attempt can
# succeed - the same shape hedging_spec.rb uses, under a name of its own so
# both files can load in the same suite.
class HedgeGateService
  include GRPC::GenericService
  rpc :an_rpc, EchoMsg, EchoMsg

  attr_reader :calls

  def initialize(fail_times: 0)
    @fail_times = fail_times
    @calls = 0
    @mu = Mutex.new
  end

  def an_rpc(req, _call)
    attempt = @mu.synchronize { @calls += 1 }
    if attempt <= @fail_times
      raise GRPC::BadStatus.new_status_exception(
        GRPC::Core::StatusCodes::UNAVAILABLE, 'hedge me')
    end
    req
  end
end
HedgeGateStub = HedgeGateService.rpc_stub_class

describe 'retry buffer and small channel arguments' do
  include GRPC::Spec::Helpers

  after(:each) do
    @server&.stop
  end

  describe GRPC::Core::ChannelArgs do
    it 'lists all four new arguments in HONOURED' do
      expect(described_class::HONOURED).to include(
        'grpc.per_rpc_retry_buffer_size',
        'grpc.absolute_max_metadata_size',
        'grpc.experimental.enable_hedging',
        'grpc.http_proxy',
        'grpc.address_http_proxy'
      )
    end

    it 'keeps HONOURED sorted' do
      expect(described_class::HONOURED).to eq(described_class::HONOURED.sort)
    end

    it 'accepts every new argument without raising' do
      expect do
        described_class.normalize(
          'grpc.per_rpc_retry_buffer_size' => 1024,
          'grpc.absolute_max_metadata_size' => 1024,
          'grpc.experimental.enable_hedging' => 1,
          'grpc.http_proxy' => 'proxy:8080',
          'grpc.address_http_proxy' => 'proxy:8080'
        )
      end.to_not raise_error
    end
  end

  # GRPC::ClientStub::RetryReplayBuffer is the object client_streamer's
  # retry loop delegates bookkeeping to. Testing it directly - rather than
  # only through a live call - is what lets this prove the buffer is
  # actually freed, not merely that a later retry does not happen (which a
  # buffer that silently kept growing forever would also satisfy).
  describe GRPC::ClientStub::RetryReplayBuffer do
    it 'buffers items and their bytes while under the limit' do
      buffer = described_class.new(10)
      buffer.add('a', 4)
      buffer.add('b', 4)
      expect(buffer.items).to eq(%w[a b])
      expect(buffer.bytes).to eq(8)
      expect(buffer.committed?).to be(false)
    end

    it 'commits and releases every held item once the limit is exceeded' do
      buffer = described_class.new(10)
      buffer.add('a', 4)
      buffer.add('b', 4)
      buffer.add('c', 4) # 12 buffered bytes now exceeds the limit of 10
      expect(buffer.committed?).to be(true)
      # Not just "no longer growing": the two already-held items are gone,
      # which is the retained-bytes assertion the buffer would fail if a
      # regression only stopped adding new items but kept the old ones.
      expect(buffer.items).to be_empty
      expect(buffer.bytes).to eq(0)
    end

    it 'stays committed and keeps ignoring further adds' do
      buffer = described_class.new(1)
      buffer.add('x', 5)
      expect(buffer.committed?).to be(true)
      buffer.add('y', 1)
      expect(buffer.items).to be_empty
      expect(buffer.bytes).to eq(0)
      expect(buffer.committed?).to be(true)
    end
  end

  describe 'client-streaming retries bounded by grpc.per_rpc_retry_buffer_size' do
    def buffered_retry_service_config
      {
        'methodConfig' => [
          {
            'name' => [{ 'service' => 'RetryBufferService', 'method' => 'a_client_streaming_rpc' }],
            'retryPolicy' => {
              'maxAttempts' => 3,
              'initialBackoff' => '0.01s',
              'maxBackoff' => '0.02s',
              'backoffMultiplier' => 1.0,
              'retryableStatusCodes' => ['UNAVAILABLE']
            }
          }
        ]
      }.to_json
    end

    def build_buffer_stub(buffer_size)
      build_rpc_server(client_opts: {
                         channel_args: {
                           'grpc.service_config' => buffered_retry_service_config,
                           'grpc.per_rpc_retry_buffer_size' => buffer_size
                         }
                       })
    end

    it 'retries a client-streaming call whose buffered requests stay under the limit' do
      build_buffer_stub(1024)
      service = RetryBufferService.new(fail_times: 1)
      run_services_on_server(@server, services: [service]) do
        stub = build_insecure_stub(RetryBufferStub)
        requests = [EchoMsg.new(msg: 'aaaa'), EchoMsg.new(msg: 'bbbb')]
        response = stub.a_client_streaming_rpc(requests)
        expect(response.msg).to eq('aaaa,bbbb')
        expect(service.calls).to eq(2)
        expect(service.received_batches).to eq([%w[aaaa bbbb], %w[aaaa bbbb]])
      end
    end

    it 'commits (and never retries) a client-streaming call whose buffered requests exceed the limit' do
      # Each EchoMsg marshals to its raw 4-byte string; the second request
      # alone pushes the running total past a limit of 5, so the buffer
      # commits before the first attempt's failure is even seen.
      build_buffer_stub(5)
      service = RetryBufferService.new(fail_times: 1)
      run_services_on_server(@server, services: [service]) do
        stub = build_insecure_stub(RetryBufferStub)
        requests = [EchoMsg.new(msg: 'aaaa'), EchoMsg.new(msg: 'bbbb')]
        expect { stub.a_client_streaming_rpc(requests) }
          .to raise_error(GRPC::Unavailable)
        # One attempt only: the retry policy allowed up to 3, but a
        # committed RPC does not get to use them.
        expect(service.calls).to eq(1)
      end
    end
  end

  describe 'grpc.absolute_max_metadata_size' do
    it 'defaults to grpc.max_metadata_size when unset' do
      channel = GRPC::Core::Channel.new('phony_host', nil, :this_channel_is_insecure)
      expect(channel.absolute_max_metadata_size).to eq(channel.max_metadata_size)
      server = GRPC::Core::Server.new({})
      expect(server.instance_variable_get(:@absolute_max_metadata_size))
        .to eq(server.instance_variable_get(:@max_metadata_size))
    end

    it 'is honoured independently of grpc.max_metadata_size' do
      channel = GRPC::Core::Channel.new(
        'phony_host', { 'grpc.absolute_max_metadata_size' => 512 }, :this_channel_is_insecure)
      expect(channel.absolute_max_metadata_size).to eq(512)
      expect(channel.max_metadata_size).to eq(GRPC::Core::ChannelArgs::DEFAULT_MAX_METADATA_SIZE)
    end

    # 2_000 bytes of metadata comfortably clears the default 8 KiB soft
    # limit (so this would pass today without the absolute cap), but not a
    # 256-byte absolute one - proving the absolute cap, not the soft one,
    # is what is actually enforced on receive.
    it 'rejects metadata between the soft default and a smaller absolute cap, on the server' do
      build_rpc_server(server_opts: { server_args: { 'grpc.absolute_max_metadata_size' => 256 } })
      run_services_on_server(@server, services: [EchoService]) do
        stub = build_insecure_stub(EchoStub)
        expect do
          stub.an_rpc(EchoMsg.new(msg: 'ok'), metadata: { 'big' => 'x' * 2_000 })
        end.to raise_error(GRPC::ResourceExhausted, /grpc.absolute_max_metadata_size/)
      end
    end

    it 'passes metadata under a smaller absolute cap, on the server' do
      build_rpc_server(server_opts: { server_args: { 'grpc.absolute_max_metadata_size' => 700 } })
      run_services_on_server(@server, services: [EchoService]) do
        stub = build_insecure_stub(EchoStub)
        expect(
          stub.an_rpc(EchoMsg.new(msg: 'ok'), metadata: { 'small' => 'x' * 10 }).msg
        ).to eq('ok')
      end
    end

    it 'rejects response metadata between the soft default and a smaller absolute cap, on the client' do
      build_rpc_server
      run_services_on_server(@server, services: [EchoService.new(big: 'x' * 2_000)]) do
        stub = build_insecure_stub(
          EchoStub,
          opts: { channel_args: { 'grpc.absolute_max_metadata_size' => 256 } })
        expect { stub.an_rpc(EchoMsg.new(msg: 'ok')) }
          .to raise_error(GRPC::ResourceExhausted, /grpc.absolute_max_metadata_size/)
      end
    end
  end

  describe 'grpc.experimental.enable_hedging' do
    def hedge_gate_service_config
      {
        'methodConfig' => [
          {
            'name' => [{ 'service' => 'HedgeGateService', 'method' => 'an_rpc' }],
            'hedgingPolicy' => {
              'maxAttempts' => 2,
              'hedgingDelay' => '0s',
              'nonFatalStatusCodes' => ['UNAVAILABLE']
            }
          }
        ]
      }.to_json
    end

    def build_hedge_gate_stub(enable_hedging: nil)
      args = { 'grpc.service_config' => hedge_gate_service_config }
      args['grpc.experimental.enable_hedging'] = enable_hedging unless enable_hedging.nil?
      build_rpc_server(client_opts: { channel_args: args })
    end

    it 'stays off when grpc.experimental.enable_hedging is explicitly 0, even with a hedgingPolicy' do
      build_hedge_gate_stub(enable_hedging: 0)
      service = HedgeGateService.new(fail_times: 1)
      run_services_on_server(@server, services: [service]) do
        stub = build_insecure_stub(HedgeGateStub)
        expect { stub.an_rpc(EchoMsg.new(msg: 'hi')) }.to raise_error(GRPC::Unavailable)
        expect(service.calls).to eq(1)
      end
    end

    it 'hedges when grpc.experimental.enable_hedging is explicitly 1' do
      build_hedge_gate_stub(enable_hedging: 1)
      service = HedgeGateService.new(fail_times: 1)
      run_services_on_server(@server, services: [service]) do
        stub = build_insecure_stub(HedgeGateStub)
        expect(stub.an_rpc(EchoMsg.new(msg: 'hi')).msg).to eq('hi')
        expect(service.calls).to eq(2)
      end
    end
  end

  describe 'proxy selection honours grpc.http_proxy and grpc.address_http_proxy' do
    around(:each) do |example|
      saved = %w[grpc_proxy https_proxy http_proxy].to_h { |name| [name, ENV[name]] }
      begin
        example.run
      ensure
        saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
      end
    end

    let(:target) { GRPC::Core::Transport::Target.new(:tcp, 'example.com', 443, nil) }

    it 'prefers the grpc.http_proxy channel argument over every proxy environment variable' do
      ENV['grpc_proxy'] = 'http://from-env:1'
      proxy = GRPC::Core::Transport.proxy_for(target, 'grpc.http_proxy' => 'http://from-arg:2')
      expect(proxy.host).to eq('from-arg')
    end

    it 'prefers the grpc.address_http_proxy channel argument over the environment' do
      ENV['http_proxy'] = 'http://from-env:1'
      proxy = GRPC::Core::Transport.proxy_for(target, 'grpc.address_http_proxy' => 'http://from-arg:2')
      expect(proxy.host).to eq('from-arg')
    end

    it 'prefers grpc.http_proxy over grpc.address_http_proxy when both are set' do
      proxy = GRPC::Core::Transport.proxy_for(
        target, 'grpc.http_proxy' => 'http://from-http-arg:1',
                'grpc.address_http_proxy' => 'http://from-address-arg:2')
      expect(proxy.host).to eq('from-http-arg')
    end

    it 'still falls back to the environment when no proxy channel argument is set' do
      ENV['http_proxy'] = 'http://from-env:1'
      proxy = GRPC::Core::Transport.proxy_for(target, {})
      expect(proxy.host).to eq('from-env')
    end
  end
end
