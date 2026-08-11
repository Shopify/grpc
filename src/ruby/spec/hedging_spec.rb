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

# grpc.service_config's hedgingPolicy was parsed and never acted on: a
# unary call configured to hedge behaved exactly like one that wasn't,
# paying hedgingPolicy's latency tax (parsing it, validating it) for none
# of its benefit (finishing on whichever of several parallel attempts
# answers first).
#
# A servicer whose behaviour is scripted per hedge attempt (0 for the
# first, 1 for the one after one hedgingDelay, ...), identified by the
# grpc-previous-rpc-attempts header the client stub attaches, so a test
# can pin down hedging's actual attempt count and timing - not just trust
# that some response eventually came back.
class HedgingService
  include GRPC::GenericService
  rpc :an_rpc, EchoMsg, EchoMsg

  Behaviour = Struct.new(:sleep_for, :status)

  attr_reader :seen_attempts

  # @param script [Array<Behaviour>] behaviour for attempt 0, 1, 2, ...; an
  #   index beyond the script succeeds immediately.
  def initialize(script)
    @script = script
    @seen_attempts = []
    @mu = Mutex.new
  end

  def an_rpc(req, call)
    index = (call.metadata['grpc-previous-rpc-attempts'] || '0').to_i
    @mu.synchronize { @seen_attempts << index }
    behaviour = @script[index] || Behaviour.new(0, nil)
    sleep(behaviour.sleep_for) if behaviour.sleep_for&.positive?
    if behaviour.status
      raise GRPC::BadStatus.new_status_exception(behaviour.status, 'scripted failure')
    end
    req
  end
end
HedgingStub = HedgingService.rpc_stub_class

describe 'hedging' do
  include GRPC::Spec::Helpers

  after(:each) do
    @server&.stop
  end

  describe GRPC::Core::ServiceConfig do
    it 'rejects a methodConfig carrying both a retryPolicy and a hedgingPolicy' do
      doc = {
        'methodConfig' => [
          {
            'name' => [{ 'service' => 'pkg.Svc', 'method' => 'Method' }],
            'retryPolicy' => {
              'maxAttempts' => 3, 'initialBackoff' => '0.1s', 'maxBackoff' => '1s',
              'backoffMultiplier' => 2, 'retryableStatusCodes' => ['UNAVAILABLE']
            },
            'hedgingPolicy' => {
              'maxAttempts' => 3, 'hedgingDelay' => '0.1s', 'nonFatalStatusCodes' => ['UNAVAILABLE']
            }
          }
        ]
      }.to_json
      expect { described_class.new(doc) }
        .to raise_error(ArgumentError, /grpc.service_config/)
    end

    it 'parses a full hedgingPolicy' do
      config = described_class.new(
        { 'methodConfig' => [
          {
            'name' => [{ 'service' => 'pkg.Svc', 'method' => 'Method' }],
            'hedgingPolicy' => {
              'maxAttempts' => 4,
              'hedgingDelay' => '0.25s',
              'nonFatalStatusCodes' => %w[UNAVAILABLE ABORTED]
            }
          }
        ] }.to_json
      )
      policy = config.method_config('/pkg.Svc/Method').hedging_policy
      expect(policy.max_attempts).to eq(4)
      expect(policy.hedging_delay).to eq(0.25)
      expect(policy.non_fatal_status_codes).to eq(
        [GRPC::Core::StatusCodes::UNAVAILABLE, GRPC::Core::StatusCodes::ABORTED]
      )
    end
  end

  describe 'a hedged unary call' do
    def hedging_service_config(max_attempts: 3, hedging_delay: '0.1s', non_fatal: [])
      {
        'methodConfig' => [
          {
            'name' => [{ 'service' => 'HedgingService', 'method' => 'an_rpc' }],
            'hedgingPolicy' => {
              'maxAttempts' => max_attempts,
              'hedgingDelay' => hedging_delay,
              'nonFatalStatusCodes' => non_fatal
            }
          }
        ]
      }.to_json
    end

    def build_hedging_stub(**opts)
      build_rpc_server(client_opts: {
                         channel_args: { 'grpc.service_config' => hedging_service_config(**opts) }
                       })
    end

    it 'fires a second attempt after hedgingDelay, returns the winner, and cancels the loser' do
      build_hedging_stub(hedging_delay: '0.1s')
      service = HedgingService.new([
                                     HedgingService::Behaviour.new(3.0, nil), # attempt 0: slow, never wins
                                     HedgingService::Behaviour.new(0, nil) # attempt 1: fast, wins
                                   ])
      run_services_on_server(@server, services: [service]) do
        stub = build_insecure_stub(HedgingStub)

        # Warm up the channel/connection before measuring thread growth,
        # so connection-lifetime housekeeping threads (e.g. keepalive)
        # that spin up on first use aren't mistaken for a hedging leak.
        # Attempt numbering restarts at each call, so this exercises (and
        # cancels) the same slow-then-fast script as the call that follows.
        stub.an_rpc(EchoMsg.new(msg: 'warmup'))

        thread_count_before = Thread.list.size
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = stub.an_rpc(EchoMsg.new(msg: 'hi'))
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        expect(response.msg).to eq('hi')
        # Waited about one hedgingDelay for attempt 1 to win, not the 3s
        # attempt 0 would have taken had hedging not run attempts in
        # parallel. request_response_hedged's ensure cancels attempt 0
        # and joins its thread before returning here, so this bound also
        # proves the cancellation actually unblocked that thread promptly
        # instead of this call waiting out attempt 0's full sleep.
        expect(elapsed).to be >= 0.1
        expect(elapsed).to be < 0.5
        expect(service.seen_attempts).to include(0, 1)
        # No thread left running past this call: every hedge thread was
        # joined in the ensure above.
        expect(Thread.list.size).to eq(thread_count_before)
      end
    end

    it 'drops a nonFatalStatusCodes failure and hedges again immediately, without waiting out the delay' do
      # hedgingDelay is deliberately far longer than the test's deadline:
      # if a nonFatalStatusCodes failure with nothing else outstanding
      # didn't trigger an immediate extra hedge, this would time out
      # waiting for the scheduled hedge instead of succeeding.
      build_hedging_stub(hedging_delay: '5s', non_fatal: ['UNAVAILABLE'])
      service = HedgingService.new([
                                     HedgingService::Behaviour.new(0, GRPC::Core::StatusCodes::UNAVAILABLE),
                                     HedgingService::Behaviour.new(0, nil)
                                   ])
      run_services_on_server(@server, services: [service]) do
        stub = build_insecure_stub(HedgingStub)
        response = stub.an_rpc(EchoMsg.new(msg: 'hi'), deadline: Time.now + 1)
        expect(response.msg).to eq('hi')
        expect(service.seen_attempts).to eq([0, 1])
      end
    end

    it 'raises immediately on a status outside nonFatalStatusCodes' do
      build_hedging_stub(hedging_delay: '5s', non_fatal: ['UNAVAILABLE'])
      service = HedgingService.new([
                                     HedgingService::Behaviour.new(0, GRPC::Core::StatusCodes::FAILED_PRECONDITION)
                                   ])
      run_services_on_server(@server, services: [service]) do
        stub = build_insecure_stub(HedgingStub)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect { stub.an_rpc(EchoMsg.new(msg: 'hi'), deadline: Time.now + 1) }
          .to raise_error(GRPC::FailedPrecondition)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        # A fatal status decides the call there and then: no waiting on
        # the 5s hedgingDelay for a second attempt that never comes.
        expect(elapsed).to be < 1.0
        expect(service.seen_attempts).to eq([0])
      end
    end

    it 'never lets a hedge attempt run past the call deadline' do
      build_hedging_stub(max_attempts: 2, hedging_delay: '10s')
      service = HedgingService.new([HedgingService::Behaviour.new(5.0, nil)])
      run_services_on_server(@server, services: [service]) do
        stub = build_insecure_stub(HedgingStub)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect { stub.an_rpc(EchoMsg.new(msg: 'hi'), deadline: Time.now + 0.2) }
          .to raise_error(GRPC::DeadlineExceeded)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        expect(elapsed).to be < 1.0
        # The 10s hedgingDelay never got a chance to fire a second,
        # equally doomed attempt before the shared deadline gave up.
        expect(service.seen_attempts).to eq([0])
      end
    end
  end
end
