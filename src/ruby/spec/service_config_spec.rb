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

# grpc.service_config was accepted and never acted on: a deployment that
# depends on its timeout, or on the retries its retryPolicy describes, saw
# neither and had no way to find out short of a client that quietly hung or
# gave up on the first UNAVAILABLE.
#
# A servicer that counts its own invocations and can be told to fail a fixed
# number of times before succeeding, so a test can assert on the number of
# attempts the client actually made and on what each attempt sent.
class RetryingService
  include GRPC::GenericService
  rpc :an_rpc, EchoMsg, EchoMsg

  attr_reader :calls, :previous_attempts

  # @param fail_times [Integer] how many leading calls fail
  # @param status [Integer] the status code those calls fail with
  # @param pushback_ms [Integer, nil] a grpc-retry-pushback-ms trailer to send
  #   alongside the failure, when set
  def initialize(fail_times: 0, status: GRPC::Core::StatusCodes::UNAVAILABLE,
                 pushback_ms: nil)
    @fail_times = fail_times
    @status = status
    @pushback_ms = pushback_ms
    @calls = 0
    @previous_attempts = []
    @mu = Mutex.new
  end

  def an_rpc(req, call)
    @mu.synchronize do
      @calls += 1
      @previous_attempts << call.metadata['grpc-previous-rpc-attempts']
      if @calls <= @fail_times
        trailers = {}
        trailers['grpc-retry-pushback-ms'] = @pushback_ms.to_s unless @pushback_ms.nil?
        raise GRPC::BadStatus.new_status_exception(@status, 'retry me', trailers)
      end
    end
    req
  end
end
RetryingStub = RetryingService.rpc_stub_class

# A server-streaming servicer that can fail a fixed number of leading calls
# before any response is yielded, and can optionally yield one response
# before failing on top of that - the second shape exists to prove a
# server-streaming retry never happens once the caller has seen a message.
class RetryingServerStreamingService
  include GRPC::GenericService
  rpc :a_server_streaming_rpc, EchoMsg, stream(EchoMsg)

  attr_reader :calls

  def initialize(fail_times: 0, yield_before_failing: false)
    @fail_times = fail_times
    @yield_before_failing = yield_before_failing
    @calls = 0
    @mu = Mutex.new
  end

  def a_server_streaming_rpc(req, _call)
    attempt = @mu.synchronize { @calls += 1 }
    Enumerator.new do |y|
      if attempt <= @fail_times
        y << req if @yield_before_failing
        raise GRPC::BadStatus.new_status_exception(
          GRPC::Core::StatusCodes::UNAVAILABLE, 'retry me')
      end
      y << req
      y << req
    end
  end
end
RetryingServerStreamingStub = RetryingServerStreamingService.rpc_stub_class

# A one-shot Enumerable: raises if #each is ever called a second time, so a
# test can prove a client-streaming retry replays its own buffered copy of
# the requests rather than re-consuming the caller's original enumerable.
class OneShotRequests
  include Enumerable

  def initialize(items)
    @items = items
    @used = false
  end

  def each(&block)
    raise 'requests enumerable consumed a second time' if @used
    @used = true
    return enum_for(:each) unless block_given?
    @items.each(&block)
  end
end

# A client-streaming servicer that records every batch of requests it
# actually received, and fails a fixed number of leading calls after
# reading the whole request stream (client-streaming has nothing to send
# back until then, so this is the only place it can fail).
class RetryingClientStreamingService
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
RetryingClientStreamingStub = RetryingClientStreamingService.rpc_stub_class

# A servicer that sleeps past a short service-config timeout, to prove the
# timeout was actually applied as the call's deadline.
class TimeoutProbeService
  include GRPC::GenericService
  rpc :an_rpc, EchoMsg, EchoMsg

  def an_rpc(req, _call)
    sleep 0.2
    req
  end
end
TimeoutProbeStub = TimeoutProbeService.rpc_stub_class

describe 'service config' do
  include GRPC::Spec::Helpers

  after(:each) do
    @server&.stop
  end

  describe GRPC::Core::ServiceConfig do
    let(:doc) do
      {
        'methodConfig' => [
          { 'name' => [{}], 'timeout' => '5s' },
          { 'name' => [{ 'service' => 'pkg.Svc' }], 'timeout' => '3s' },
          {
            'name' => [{ 'service' => 'pkg.Svc', 'method' => 'Method' }],
            'timeout' => '1s'
          }
        ]
      }.to_json
    end
    subject { described_class.new(doc) }

    it 'prefers an exact service+method match' do
      expect(subject.method_config('/pkg.Svc/Method').timeout).to eq(1.0)
    end

    it 'falls back to a service-wide match when the method differs' do
      expect(subject.method_config('/pkg.Svc/Other').timeout).to eq(3.0)
    end

    it 'falls back to the channel default for an unrelated service' do
      expect(subject.method_config('/other.Svc/Foo').timeout).to eq(5.0)
    end

    it 'returns nil when there is no default and nothing else matches' do
      config = described_class.new(
        { 'methodConfig' => [
          { 'name' => [{ 'service' => 'pkg.Svc' }], 'timeout' => '1s' }
        ] }.to_json
      )
      expect(config.method_config('/other.Svc/Foo')).to be_nil
    end

    it 'parses a full retryPolicy' do
      config = described_class.new(
        { 'methodConfig' => [
          {
            'name' => [{ 'service' => 'pkg.Svc', 'method' => 'Method' }],
            'retryPolicy' => {
              'maxAttempts' => 4,
              'initialBackoff' => '0.1s',
              'maxBackoff' => '1s',
              'backoffMultiplier' => 2,
              'retryableStatusCodes' => %w[UNAVAILABLE DEADLINE_EXCEEDED]
            }
          }
        ] }.to_json
      )
      policy = config.method_config('/pkg.Svc/Method').retry_policy
      expect(policy.max_attempts).to eq(4)
      expect(policy.initial_backoff).to eq(0.1)
      expect(policy.max_backoff).to eq(1.0)
      expect(policy.backoff_multiplier).to eq(2.0)
      expect(policy.retryable_status_codes).to eq(
        [GRPC::Core::StatusCodes::UNAVAILABLE, GRPC::Core::StatusCodes::DEADLINE_EXCEEDED]
      )
    end

    it 'rejects malformed JSON, naming the argument' do
      expect { described_class.new('not json') }
        .to raise_error(ArgumentError, /grpc.service_config/)
    end

    it 'rejects a retryPolicy missing a required field' do
      expect do
        described_class.new(
          { 'methodConfig' => [
            { 'name' => [{}], 'retryPolicy' => { 'maxAttempts' => 3 } }
          ] }.to_json
        )
      end.to raise_error(ArgumentError, /grpc.service_config/)
    end
  end

  describe GRPC::Core::Channel do
    it 'fails to build rather than silently ignore a broken service config' do
      expect do
        described_class.new('localhost:0', { 'grpc.service_config' => '{bad json' },
                            :this_channel_is_insecure)
      end.to raise_error(ArgumentError, /grpc.service_config/)
    end
  end

  # Applying the method-config timeout as the deadline
  describe 'timeout' do
    it 'is applied when the caller supplies no deadline' do
      service_config = {
        'methodConfig' => [
          {
            'name' => [{ 'service' => 'TimeoutProbeService', 'method' => 'an_rpc' }],
            'timeout' => '0.05s'
          }
        ]
      }.to_json
      build_rpc_server(client_opts: {
                         channel_args: { 'grpc.service_config' => service_config }
                       })
      run_services_on_server(@server, services: [TimeoutProbeService]) do
        stub = build_insecure_stub(TimeoutProbeStub)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect { stub.an_rpc(EchoMsg.new(msg: 'hi')) }
          .to raise_error(GRPC::DeadlineExceeded)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        # Well under the servicer's 0.2s sleep: the short configured timeout,
        # not the servicer's own pace, ended the call.
        expect(elapsed).to be < 0.15
      end
    end
  end

  # Retries, gated on grpc.enable_retries defaulting on for a retryPolicy
  describe 'retries' do
    def service_config(max_attempts: 3, retryable: ['UNAVAILABLE'])
      {
        'methodConfig' => [
          {
            'name' => [{ 'service' => 'RetryingService', 'method' => 'an_rpc' }],
            'retryPolicy' => {
              'maxAttempts' => max_attempts,
              'initialBackoff' => '0.01s',
              'maxBackoff' => '0.02s',
              'backoffMultiplier' => 1.0,
              'retryableStatusCodes' => retryable
            }
          }
        ]
      }.to_json
    end

    def build_retrying_stub(**opts)
      build_rpc_server(client_opts: {
                         channel_args: { 'grpc.service_config' => service_config(**opts) }
                       })
    end

    it 'retries a retryable status until the server succeeds' do
      build_retrying_stub
      service = RetryingService.new(fail_times: 2)
      run_services_on_server(@server, services: [service]) do
        stub = build_insecure_stub(RetryingStub)
        response = stub.an_rpc(EchoMsg.new(msg: 'hi'))
        expect(response.msg).to eq('hi')
        expect(service.calls).to eq(3)
      end
    end

    it 'sends grpc-previous-rpc-attempts starting on the second attempt' do
      build_retrying_stub
      service = RetryingService.new(fail_times: 2)
      run_services_on_server(@server, services: [service]) do
        stub = build_insecure_stub(RetryingStub)
        stub.an_rpc(EchoMsg.new(msg: 'hi'))
        expect(service.previous_attempts).to eq([nil, '1', '2'])
      end
    end

    it 'does not retry a status outside retryableStatusCodes' do
      build_retrying_stub(retryable: ['UNAVAILABLE'])
      service = RetryingService.new(
        fail_times: 1, status: GRPC::Core::StatusCodes::FAILED_PRECONDITION
      )
      run_services_on_server(@server, services: [service]) do
        stub = build_insecure_stub(RetryingStub)
        expect { stub.an_rpc(EchoMsg.new(msg: 'hi')) }
          .to raise_error(GRPC::FailedPrecondition)
        expect(service.calls).to eq(1)
      end
    end

    it 'does not retry once the RPC has committed by succeeding' do
      build_retrying_stub(max_attempts: 5)
      service = RetryingService.new(fail_times: 0)
      run_services_on_server(@server, services: [service]) do
        stub = build_insecure_stub(RetryingStub)
        stub.an_rpc(EchoMsg.new(msg: 'hi'))
        expect(service.calls).to eq(1)
      end
    end

    it 'stops retrying on a negative grpc-retry-pushback-ms' do
      build_retrying_stub(max_attempts: 5)
      service = RetryingService.new(fail_times: 5, pushback_ms: -1)
      run_services_on_server(@server, services: [service]) do
        stub = build_insecure_stub(RetryingStub)
        expect { stub.an_rpc(EchoMsg.new(msg: 'hi')) }
          .to raise_error(GRPC::Unavailable)
        expect(service.calls).to eq(1)
      end
    end

    it 'honours a non-negative grpc-retry-pushback-ms even for a status ' \
       'outside retryableStatusCodes' do
      build_retrying_stub(retryable: ['DATA_LOSS'])
      service = RetryingService.new(fail_times: 1, pushback_ms: 5)
      run_services_on_server(@server, services: [service]) do
        stub = build_insecure_stub(RetryingStub)
        response = stub.an_rpc(EchoMsg.new(msg: 'hi'))
        expect(response.msg).to eq('hi')
        expect(service.calls).to eq(2)
      end
    end
  end

  describe 'server-streaming retries' do
    def streaming_service_config(max_attempts: 3)
      {
        'methodConfig' => [
          {
            'name' => [{ 'service' => 'RetryingServerStreamingService',
                         'method' => 'a_server_streaming_rpc' }],
            'retryPolicy' => {
              'maxAttempts' => max_attempts,
              'initialBackoff' => '0.01s',
              'maxBackoff' => '0.02s',
              'backoffMultiplier' => 1.0,
              'retryableStatusCodes' => ['UNAVAILABLE']
            }
          }
        ]
      }.to_json
    end

    def build_streaming_retry_stub(**opts)
      build_rpc_server(client_opts: {
                         channel_args: { 'grpc.service_config' => streaming_service_config(**opts) }
                       })
    end

    it 'retries a server-streaming call while nothing has been yielded yet' do
      build_streaming_retry_stub
      service = RetryingServerStreamingService.new(fail_times: 2)
      run_services_on_server(@server, services: [service]) do
        stub = build_insecure_stub(RetryingServerStreamingStub)
        responses = stub.a_server_streaming_rpc(EchoMsg.new(msg: 'hi')).to_a
        expect(responses.map(&:msg)).to eq(%w[hi hi])
        expect(service.calls).to eq(3)
      end
    end

    it 'does not retry once a response has been yielded to the caller' do
      build_streaming_retry_stub
      service = RetryingServerStreamingService.new(fail_times: 1, yield_before_failing: true)
      run_services_on_server(@server, services: [service]) do
        stub = build_insecure_stub(RetryingServerStreamingStub)
        responses = stub.a_server_streaming_rpc(EchoMsg.new(msg: 'hi'))
        expect(responses.next.msg).to eq('hi') # committed: the caller has now seen a message
        expect { responses.next }.to raise_error(GRPC::Unavailable)
        expect(service.calls).to eq(1)
      end
    end
  end

  describe 'client-streaming retries' do
    def streaming_service_config(max_attempts: 3)
      {
        'methodConfig' => [
          {
            'name' => [{ 'service' => 'RetryingClientStreamingService',
                         'method' => 'a_client_streaming_rpc' }],
            'retryPolicy' => {
              'maxAttempts' => max_attempts,
              'initialBackoff' => '0.01s',
              'maxBackoff' => '0.02s',
              'backoffMultiplier' => 1.0,
              'retryableStatusCodes' => ['UNAVAILABLE']
            }
          }
        ]
      }.to_json
    end

    def build_streaming_retry_stub(**opts)
      build_rpc_server(client_opts: {
                         channel_args: { 'grpc.service_config' => streaming_service_config(**opts) }
                       })
    end

    it 'replays the buffered requests on a retried attempt' do
      build_streaming_retry_stub
      service = RetryingClientStreamingService.new(fail_times: 1)
      run_services_on_server(@server, services: [service]) do
        stub = build_insecure_stub(RetryingClientStreamingStub)
        # A one-shot Enumerable: if the retry re-consumed it instead of
        # replaying its own buffered copy, this would raise on attempt 2.
        requests = OneShotRequests.new([EchoMsg.new(msg: 'a'), EchoMsg.new(msg: 'b')])
        response = stub.a_client_streaming_rpc(requests)
        expect(response.msg).to eq('a,b')
        expect(service.calls).to eq(2)
        expect(service.received_batches).to eq([%w[a b], %w[a b]])
      end
    end
  end
end
