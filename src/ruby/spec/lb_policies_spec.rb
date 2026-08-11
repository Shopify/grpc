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
require 'timeout'

# ring_hash (gRFC A42) and weighted_round_robin (gRFC A58): two more
# grpc.lb_policy_name entries alongside pick_first and round_robin, covered
# generically by resolver_lb_spec.rb's connectivity-aggregation specs.
describe 'ring_hash and weighted_round_robin LB policies' do
  include GRPC::Spec::Helpers

  # Polls instead of sleeping a fixed amount, matching resolver_lb_spec.rb.
  def wait_until(timeout = 2.0)
    deadline = Time.now + timeout
    loop do
      return true if yield
      return false if Time.now > deadline
      sleep 0.005
    end
  end

  # A Subchannel with no real socket, addressed by a Target so ring_hash can
  # read its host:port for a ring key and weighted_round_robin can read its
  # weight, exactly as a resolved address would carry either. +host+ must be
  # distinct per subchannel: ring_hash keys its ring entries by host:port,
  # and two subchannels sharing one would collide on the ring.
  def fake_subchannel(behavior, host:, weight: nil)
    address = GRPC::Core::Transport::Target.new(:tcp, host, 443, nil, nil, weight)
    dial = lambda do |_address, _on_close|
      raise 'connection refused' if behavior == :fail
      double('connection', alive?: true, close: nil, outlier_counter: nil, 'outlier_counter=': nil)
    end
    GRPC::Core::Subchannel.new(address, dial: dial)
  end

  # Connects every subchannel and blocks until each is alive, so a pick
  # below is exercising steady-state behaviour rather than racing dial.
  def ready_subchannels(subchannels)
    subchannels.each(&:maybe_connect)
    wait_until { subchannels.all?(&:alive?) }
    subchannels
  end

  def failed_subchannel(host:, weight: nil)
    dead = fake_subchannel(:fail, host: host, weight: weight)
    dead.maybe_connect
    wait_until { dead.state == GRPC::Core::ConnectivityStates::TRANSIENT_FAILURE }
    dead
  end

  describe GRPC::Core::RingHashPolicy do
    it 'sends the same hash key to the same address on every pick' do
      subchannels = ready_subchannels(Array.new(4) { |i| fake_subchannel(:ready, host: "10.0.0.#{i}") })
      policy = described_class.new(subchannels)

      first = policy.pick('customer-42')
      expect(first).not_to be_nil
      10.times { expect(policy.pick('customer-42')).to equal(first) }
    end

    it 'moves only a bounded, roughly-proportional share of keys when an address leaves the ring' do
      subchannels = ready_subchannels(Array.new(10) { |i| fake_subchannel(:ready, host: "10.0.1.#{i}") })
      ring_before = described_class.new(subchannels)
      keys = Array.new(2000) { |i| "key-#{i}" }
      picks_before = keys.to_h { |k| [k, ring_before.pick(k)] }

      ring_after = described_class.new(subchannels[0..-2]) # the last address leaves

      changed = keys.count { |k| !ring_after.pick(k).equal?(picks_before[k]) }
      fraction_changed = changed.to_f / keys.size

      # Rebuilding the ring recomputes every surviving address's normalized
      # weight (its share of the *new* total), so a few of their points
      # shift too -- this is not the "only the departing address's own keys
      # move" guarantee of an unweighted ring, only a bounded approximation
      # of it (see ring_hash.cc, which this ports). Still nowhere near a
      # full reshuffle (~90% of keys for 10 equal-weight addresses), and in
      # the neighbourhood of the one-in-ten share the departing address held.
      expect(fraction_changed).to be > 0.02
      expect(fraction_changed).to be < 0.5
    end

    it "honours grpc.lb.ring_hash.ring_size_cap" do
      subchannels = ready_subchannels(Array.new(4) { |i| fake_subchannel(:ready, host: "10.0.2.#{i}") })
      policy = described_class.new(subchannels, { 'grpc.lb.ring_hash.ring_size_cap' => 8 })

      expect(policy.instance_variable_get(:@ring_hashes).size).to eq(8)
    end

    it 'skips an address whose subchannel has failed and finds the next one clockwise' do
      live = ready_subchannels([fake_subchannel(:ready, host: '10.0.3.1')]).first
      dead = failed_subchannel(host: '10.0.3.2')
      policy = described_class.new([live, dead])

      50.times { |i| expect(policy.pick("k#{i}")).to equal(live) }
    end
  end

  describe GRPC::Core::WeightedRoundRobinPolicy do
    it 'splits picks across ready subchannels in exact proportion to their weights over one full cycle' do
      heavy = fake_subchannel(:ready, host: '10.0.4.1', weight: 3)
      light = fake_subchannel(:ready, host: '10.0.4.2', weight: 1)
      ready_subchannels([heavy, light])
      policy = described_class.new([heavy, light])

      picks = Array.new(4) { policy.pick }
      expect(picks.count { |sc| sc.equal?(heavy) }).to eq(3)
      expect(picks.count { |sc| sc.equal?(light) }).to eq(1)
    end

    it 'adapts the split when the weights change' do
      a = fake_subchannel(:ready, host: '10.0.5.1', weight: 1)
      b = fake_subchannel(:ready, host: '10.0.5.2', weight: 3)
      ready_subchannels([a, b])
      policy = described_class.new([a, b])

      picks = Array.new(4) { policy.pick }
      expect(picks.count { |sc| sc.equal?(b) }).to eq(3)
      expect(picks.count { |sc| sc.equal?(a) }).to eq(1)
    end

    it 'skips a subchannel that is not usable and keeps returning the live one' do
      dead = failed_subchannel(host: '10.0.6.1', weight: 10)
      live = ready_subchannels([fake_subchannel(:ready, host: '10.0.6.2', weight: 1)]).first
      policy = described_class.new([dead, live])

      expect(Array.new(20) { policy.pick }.uniq).to eq([live])
    end

    it 'treats every non-positive weight as 1, never 0, so scheduling cannot divide by a zero gcd' do
      first = fake_subchannel(:ready, host: '10.0.7.1', weight: 0)
      second = fake_subchannel(:ready, host: '10.0.7.2', weight: -1)
      ready_subchannels([first, second])
      policy = described_class.new([first, second])

      # Both weights collapsing to a real 0 would leave @gcd (0.gcd(0) == 0)
      # zero, and #advance_locked's "@current_weight -= @gcd" would never
      # reach the reset branch -- an infinite loop, not a wrong answer.
      Timeout.timeout(2) do
        expect(Array.new(4) { policy.pick }).to all(be_a(GRPC::Core::Subchannel))
      end
    end
  end

  describe 'grpc.lb_policy_name registration' do
    it 'registers ring_hash and weighted_round_robin' do
      expect(GRPC::Core::LB_POLICIES['ring_hash']).to eq(GRPC::Core::RingHashPolicy)
      expect(GRPC::Core::LB_POLICIES['weighted_round_robin']).to eq(GRPC::Core::WeightedRoundRobinPolicy)
    end

    it 'still rejects an lb_policy_name neither of them, or anything else, implements' do
      expect do
        GRPC::Core::Channel.new('localhost:1', { 'grpc.lb_policy_name' => 'grpclb' },
                                :this_channel_is_insecure)
      end.to raise_error(ArgumentError, /grpc.lb_policy_name/)
    end

    it 'accepts ring_hash and weighted_round_robin as grpc.lb_policy_name' do
      %w[ring_hash weighted_round_robin].each do |name|
        ch = GRPC::Core::Channel.new('localhost:1', { 'grpc.lb_policy_name' => name },
                                     :this_channel_is_insecure)
        expect(ch.instance_variable_get(:@lb_policy_name)).to eq(name)
        ch.close
      end
    end
  end

  it 'honours grpc.lb.ring_hash.ring_size_cap as an implemented channel argument' do
    expect do
      GRPC::Core::Channel.new('localhost:1', { 'grpc.lb.ring_hash.ring_size_cap' => 8 },
                              :this_channel_is_insecure).close
    end.not_to raise_error
  end

  describe 'ring_hash consistency through a live Channel' do
    it 'sends every call under the same x-grpc-hash-key to the same backend' do
      servers = Array.new(2) { build_counting_server }
      begin
        addresses = servers.map { |s| GRPC::Core::Transport::Target.new(:tcp, '127.0.0.1', s[:port], nil) }
        allow(GRPC::Core::Transport).to receive(:resolve_addresses) do |target|
          target.addresses = addresses
        end
        channel_args = { 'grpc.lb_policy_name' => 'ring_hash' }
        stub = build_insecure_stub(EchoStub, host: 'multi-rh.example:443',
                                             opts: { channel_args: channel_args })

        # Warm up so both subchannels are READY before the calls under test:
        # ring_hash's #maybe_connect dials every address, not just whichever
        # one a given key happens to land on.
        8.times do |i|
          stub.an_rpc(EchoMsg.new(msg: 'warm'), metadata: { 'x-grpc-hash-key' => "warm-#{i}" },
                                                deadline: Time.now + 5)
        end
        counts_before = servers.map { |s| s[:count].call }

        10.times do
          stub.an_rpc(EchoMsg.new(msg: 'sticky'), metadata: { 'x-grpc-hash-key' => 'same-customer' },
                                                  deadline: Time.now + 5)
        end

        deltas = servers.map { |s| s[:count].call }.zip(counts_before).map { |after, before| after - before }
        expect(deltas.count(&:positive?)).to eq(1)
        expect(deltas.max).to eq(10)
      ensure
        servers.each do |s|
          s[:server].stop
          s[:thread].join
        end
      end
    end
  end

  # A counting RpcServer independent of the @server/@port GRPC::Spec::Helpers
  # manages, so ring_hash has two distinct live addresses to choose between.
  def build_counting_server
    server = new_rpc_server_for_testing(poll_period: 1)
    port = server.add_http2_port('127.0.0.1:0', :this_port_is_insecure)
    mu = Mutex.new
    count = 0
    service = EchoService.new
    service.on_call_started = ->(_call) { mu.synchronize { count += 1 } }
    server.handle(service)
    thread = Thread.new { server.run }
    server.wait_till_running
    { server: server, thread: thread, port: port, count: -> { mu.synchronize { count } } }
  end
end
