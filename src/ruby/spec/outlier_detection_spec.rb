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

# A test service whose an_rpc fails whenever +should_fail+ says so, so a
# live Channel has a real backend to eject -- distinct from EchoService,
# which always succeeds and has no way to simulate a bad address.
class OutlierProneService
  include GRPC::GenericService
  rpc :an_rpc, EchoMsg, EchoMsg

  attr_reader :calls

  def initialize(&should_fail)
    @should_fail = should_fail
    @mu = Mutex.new
    @calls = 0
  end

  def an_rpc(req, _call)
    @mu.synchronize { @calls += 1 }
    fail GRPC::Unavailable, 'synthetic failure' if @should_fail.call
    req
  end
end
OutlierProneStub = OutlierProneService.rpc_stub_class

describe 'outlier detection (gRFC A50)' do
  include GRPC::Spec::Helpers

  def wait_until(timeout = 3.0)
    deadline = Time.now + timeout
    loop do
      return true if yield
      return false if Time.now > deadline
      sleep 0.005
    end
  end

  # A Subchannel with no real socket, always able to dial successfully, so
  # ejection/pick behaviour can be proven without a network. Mirrors
  # resolver_lb_spec.rb's fake_subchannel.
  def fake_subchannel
    dial = lambda do |_address, _on_close|
      double('connection', alive?: true, close: nil).tap { |d| allow(d).to receive(:outlier_counter=) }
    end
    sc = GRPC::Core::Subchannel.new(:fake_address, dial: dial)
    sc.maybe_connect
    wait_until { sc.alive? }
    sc
  end

  # +success+ and +failure+ are call counts recorded directly on the
  # address's counter, standing in for real RPCs finishing through
  # Call#op_recv_status.
  def subchannel_with_counts(policy_subchannels_index, success:, failure:)
    sc = policy_subchannels_index
    success.times { sc.outlier_counter.record(true) }
    failure.times { sc.outlier_counter.record(false) }
    sc
  end

  def success_rate_config(overrides = {})
    GRPC::Core::OutlierDetection::Config.new({
      interval: 10.0, base_ejection_time: 10.0, max_ejection_time: 300.0, max_ejection_percent: 50,
      success_rate_stdev_factor: 500, success_rate_enforcement_percentage: 100,
      success_rate_minimum_hosts: 2, success_rate_request_volume: 10,
      failure_percentage_threshold: nil, failure_percentage_enforcement_percentage: nil,
      failure_percentage_minimum_hosts: nil, failure_percentage_request_volume: nil
    }.merge(overrides))
  end

  def failure_percentage_config(overrides = {})
    GRPC::Core::OutlierDetection::Config.new({
      interval: 10.0, base_ejection_time: 10.0, max_ejection_time: 300.0, max_ejection_percent: 50,
      success_rate_stdev_factor: nil, success_rate_enforcement_percentage: nil,
      success_rate_minimum_hosts: nil, success_rate_request_volume: nil,
      failure_percentage_threshold: 50, failure_percentage_enforcement_percentage: 100,
      failure_percentage_minimum_hosts: 2, failure_percentage_request_volume: 10
    }.merge(overrides))
  end

  describe GRPC::Core::OutlierDetectionPolicy do
    describe 'the success rate algorithm' do
      it 'ejects an address whose success rate is far below its peers, and pick stops returning it' do
        subchannels = Array.new(4) { fake_subchannel }
        child = GRPC::Core::RoundRobinPolicy.new(subchannels)
        policy = described_class.new(subchannels, child, success_rate_config)

        subchannels[0..2].each { |sc| subchannel_with_counts(sc, success: 20, failure: 0) }
        bad = subchannel_with_counts(subchannels[3], success: 10, failure: 10) # 50%, peers are 100%

        policy.evaluate(0)

        expect(bad.alive?).to be(false)
        picks = Array.new(30) { policy.pick }.compact
        expect(picks).not_to be_empty
        expect(picks.uniq).not_to include(bad)
      end

      it 'does not eject when every address performs about the same' do
        subchannels = Array.new(4) { fake_subchannel }
        child = GRPC::Core::RoundRobinPolicy.new(subchannels)
        policy = described_class.new(subchannels, child, success_rate_config)
        subchannels.each { |sc| subchannel_with_counts(sc, success: 19, failure: 1) }

        policy.evaluate(0)

        expect(subchannels.all?(&:alive?)).to be(true)
      end

      it 'requestVolume suppresses ejection when an address has too few calls' do
        subchannels = Array.new(4) { fake_subchannel }
        child = GRPC::Core::RoundRobinPolicy.new(subchannels)
        policy = described_class.new(subchannels, child, success_rate_config(success_rate_request_volume: 100))
        subchannels[0..2].each { |sc| subchannel_with_counts(sc, success: 20, failure: 0) }
        bad = subchannel_with_counts(subchannels[3], success: 1, failure: 19) # 5%, but under the volume floor

        policy.evaluate(0)

        expect(bad.alive?).to be(true)
      end

      it 'minimumHosts suppresses the whole algorithm when too few addresses have enough data' do
        subchannels = Array.new(4) { fake_subchannel }
        child = GRPC::Core::RoundRobinPolicy.new(subchannels)
        policy = described_class.new(subchannels, child, success_rate_config(success_rate_minimum_hosts: 5))
        subchannels[0..2].each { |sc| subchannel_with_counts(sc, success: 20, failure: 0) }
        bad = subchannel_with_counts(subchannels[3], success: 0, failure: 20)

        policy.evaluate(0)

        expect(bad.alive?).to be(true)
      end
    end

    describe 'the failure percentage algorithm' do
      it 'ejects an address whose failure percentage exceeds the threshold' do
        subchannels = Array.new(3) { fake_subchannel }
        child = GRPC::Core::RoundRobinPolicy.new(subchannels)
        policy = described_class.new(subchannels, child, failure_percentage_config)
        subchannels[0..1].each { |sc| subchannel_with_counts(sc, success: 10, failure: 0) }
        bad = subchannel_with_counts(subchannels[2], success: 2, failure: 8) # 80% > 50% threshold

        policy.evaluate(0)

        expect(bad.alive?).to be(false)
      end

      it 'never ejects more than maxEjectionPercent of addresses, even when most are failing' do
        subchannels = Array.new(4) { fake_subchannel }
        child = GRPC::Core::RoundRobinPolicy.new(subchannels)
        policy = described_class.new(subchannels, child, failure_percentage_config(max_ejection_percent: 50))
        subchannels.each { |sc| subchannel_with_counts(sc, success: 0, failure: 10) } # every address is 100% failing

        policy.evaluate(0)

        ejected = subchannels.reject(&:alive?)
        expect(ejected.size).to eq(2) # 50% of 4, never more
      end

      it 'requestVolume and minimumHosts suppress ejection on thin data' do
        subchannels = Array.new(3) { fake_subchannel }
        child = GRPC::Core::RoundRobinPolicy.new(subchannels)
        policy = described_class.new(subchannels, child, failure_percentage_config(failure_percentage_request_volume: 50))
        subchannels[0..1].each { |sc| subchannel_with_counts(sc, success: 10, failure: 0) }
        bad = subchannel_with_counts(subchannels[2], success: 0, failure: 10) # 100% failing, but under the volume floor

        policy.evaluate(0)

        expect(bad.alive?).to be(true)
      end
    end

    it 'un-ejects an address once its next interval carries no fresh reason to reject it' do
      subchannels = Array.new(3) { fake_subchannel }
      child = GRPC::Core::RoundRobinPolicy.new(subchannels)
      policy = described_class.new(subchannels, child, failure_percentage_config(base_ejection_time: 10.0))
      subchannels[0..1].each { |sc| subchannel_with_counts(sc, success: 10, failure: 0) }
      bad = subchannel_with_counts(subchannels[2], success: 0, failure: 10)

      policy.evaluate(0)
      expect(bad.alive?).to be(false)

      policy.evaluate(5) # base_ejection_time (10s) has not elapsed yet
      expect(bad.alive?).to be(false)

      policy.evaluate(11) # 11s elapsed, past base_ejection_time * ejection_count (10 * 1)
      expect(bad.alive?).to be(true)
    end
  end

  describe GRPC::Core::OutlierDetection::Tracker do
    it 'backs off further on each successive ejection, and caps at maxEjectionTime' do
      subchannel = fake_subchannel
      tracker = described_class.new(subchannel)

      tracker.eject(0)
      expect(subchannel.alive?).to be(false)
      tracker.maybe_uneject(9, 10.0, 100.0) # under base_ejection_time * 1 (10)
      expect(subchannel.alive?).to be(false)
      tracker.maybe_uneject(11, 10.0, 100.0) # past it
      expect(subchannel.alive?).to be(true)
      expect(tracker.ejection_count).to eq(1)

      tracker.eject(11) # second ejection: needs base_ejection_time * 2 (20) this time
      expect(tracker.ejection_count).to eq(2)
      tracker.maybe_uneject(11 + 19, 10.0, 100.0)
      expect(subchannel.alive?).to be(false)
      tracker.maybe_uneject(11 + 21, 10.0, 100.0)
      expect(subchannel.alive?).to be(true)

      tracker.eject(32) # third ejection would need base_ejection_time * 3 (30), but maxEjectionTime caps it at 25
      expect(tracker.ejection_count).to eq(3)
      tracker.maybe_uneject(32 + 24, 10.0, 25.0)
      expect(subchannel.alive?).to be(false)
      tracker.maybe_uneject(32 + 26, 10.0, 25.0)
      expect(subchannel.alive?).to be(true)
    end
  end

  # A second live RpcServer with its own call counter and failure switch, so
  # a real Channel has two distinct addresses -- one healthy, one bad -- to
  # choose between.
  def build_outlier_prone_server(&should_fail)
    server = new_rpc_server_for_testing(poll_period: 1)
    port = server.add_http2_port('127.0.0.1:0', :this_port_is_insecure)
    service = OutlierProneService.new(&should_fail)
    server.handle(service)
    thread = Thread.new { server.run }
    server.wait_till_running
    { server: server, thread: thread, port: port, service: service }
  end

  def stub_addresses(*targets)
    allow(GRPC::Core::Transport).to receive(:resolve_addresses) do |target|
      target.addresses = targets
    end
  end

  describe 'end to end through a Channel' do
    it 'ejects a backend failing every call, so round_robin stops sending it traffic, ' \
       'while the healthy backend keeps answering' do
      good = build_outlier_prone_server { false }
      bad = build_outlier_prone_server { true }
      begin
        stub_addresses(GRPC::Core::Transport::Target.new(:tcp, '127.0.0.1', good[:port], nil),
                       GRPC::Core::Transport::Target.new(:tcp, '127.0.0.1', bad[:port], nil))
        service_config = {
          outlierDetection: {
            interval: '0.2s', baseEjectionTime: '30s', maxEjectionTime: '300s', maxEjectionPercent: 50,
            failurePercentageEjection: {
              threshold: 50, enforcementPercentage: 100, minimumHosts: 1, requestVolume: 3
            }
          }
        }.to_json
        channel_args = { 'grpc.lb_policy_name' => 'round_robin', 'grpc.service_config' => service_config }
        stub = build_insecure_stub(OutlierProneStub, host: 'outlier-e2e.example:443',
                                                     opts: { channel_args: channel_args })

        # Warm up both subchannels so round_robin has both READY.
        4.times do
          stub.an_rpc(EchoMsg.new(msg: 'warm'), deadline: Time.now + 5)
        rescue GRPC::BadStatus
          nil
        end
        expect(wait_until { good[:service].calls.positive? && bad[:service].calls.positive? }).to be(true)

        # Each evaluation interval only sees the calls that landed since the
        # last one -- #snapshot! resets the counters -- so requestVolume
        # must clear within a single 0.2s window: fire a burst of calls
        # instead of trickling them in one at a time. Once ejected, every
        # call lands on the healthy backend, so a whole burst causing no
        # growth on the bad server is the signal to poll for.
        expect(wait_until(6.0) do
          before = bad[:service].calls
          8.times do
            stub.an_rpc(EchoMsg.new(msg: 'probe'), deadline: Time.now + 5)
          rescue GRPC::BadStatus
            nil
          end
          bad[:service].calls == before
        end).to be(true)

        steady = bad[:service].calls
        5.times { expect(stub.an_rpc(EchoMsg.new(msg: 'after'), deadline: Time.now + 5).msg).to eq('after') }
        expect(bad[:service].calls).to eq(steady)
      ensure
        [good, bad].each do |s|
          s[:server].stop
          s[:thread].join
        end
      end
    end
  end
end
