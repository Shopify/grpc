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
end
