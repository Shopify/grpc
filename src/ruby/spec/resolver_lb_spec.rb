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

# A target used to resolve to whatever a single getaddrinfo call happened to
# return, and a Channel held exactly one connection. Real DNS names can have
# several A/AAAA records, and a caller who wants every RPC on the same dead
# address to keep failing has no recourse without resolving them all and
# picking among them. SRV records and service config over DNS TXT are
# covered by dns_srv_spec.rb.
AddressTarget = GRPC::Core::Transport::Target
States = GRPC::Core::ConnectivityStates
describe 'DNS resolution to multiple addresses and load balancing' do
  include GRPC::Spec::Helpers

  # Polls instead of sleeping a fixed amount, so the spec is both fast on a
  # healthy run and not flaky under load.
  def wait_until(timeout = 2.0)
    deadline = Time.now + timeout
    loop do
      return true if yield
      return false if Time.now > deadline
      sleep 0.005
    end
  end

  # A Subchannel with no real socket: +behavior+ is :ready to succeed
  # instantly or :fail to raise, so LB policy behaviour can be proven
  # without a network.
  def fake_subchannel(behavior)
    dial = lambda do |_address, _on_close|
      raise 'connection refused' if behavior == :fail
      double('connection', alive?: true, close: nil)
    end
    GRPC::Core::Subchannel.new(:fake_address, dial: dial)
  end

  # A TCP port nothing is listening on, so a connection attempt to it fails
  # immediately instead of hanging.
  def dead_target
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    server.close
    AddressTarget.new(:tcp, '127.0.0.1', port, nil)
  end

  # Makes every channel built while the block runs resolve @parsed_target to
  # +targets+, standing in for the DNS answer a real resolver would give.
  def stub_addresses(*targets)
    allow(GRPC::Core::Transport).to receive(:resolve_addresses) do |target|
      target.addresses = targets
    end
  end

  describe GRPC::Core::Transport do
    it 'enumerates every address a name resolves to, not just the first' do
      addrinfos = ['10.0.0.1', '10.0.0.2', '::1'].map do |ip|
        instance_double(Addrinfo, ip_address: ip)
      end
      allow(Addrinfo).to receive(:getaddrinfo)
        .with('multi.example', 443, nil, :STREAM).and_return(addrinfos)
      target = AddressTarget.new(:tcp, 'multi.example', 443, nil)

      addresses = described_class.resolve_addresses(target)

      expect(addresses.map(&:host)).to eq(%w[10.0.0.1 10.0.0.2 ::1])
      expect(addresses.map(&:port)).to eq([443, 443, 443])
      expect(target.addresses).to equal(addresses)
    end

    it 'drops duplicate addresses a resolver reported twice' do
      addrinfos = ['10.0.0.1', '10.0.0.1'].map { |ip| instance_double(Addrinfo, ip_address: ip) }
      allow(Addrinfo).to receive(:getaddrinfo).and_return(addrinfos)
      target = AddressTarget.new(:tcp, 'dup.example', 443, nil)
      expect(described_class.resolve_addresses(target).size).to eq(1)
    end

    it 'has nothing to resolve for a unix target' do
      target = described_class.parse_target('unix:/tmp/some.sock')
      expect(described_class.resolve_addresses(target)).to eq([target])
    end
  end

  describe 'connectivity across several subchannels' do
    it 'is READY if any subchannel is ready, even with another failed' do
      ready = fake_subchannel(:ready)
      failed = fake_subchannel(:fail)
      ready.maybe_connect
      failed.maybe_connect
      expect(wait_until { ready.alive? && failed.state == States::TRANSIENT_FAILURE }).to be(true)

      expect(GRPC::Core::LbPolicyState.aggregate([ready, failed])).to eq(States::READY)
    end

    it 'is TRANSIENT_FAILURE only once every subchannel has failed' do
      a = fake_subchannel(:fail)
      b = fake_subchannel(:fail)
      a.maybe_connect
      b.maybe_connect
      expect(wait_until do
        [a, b].all? { |sc| sc.state == States::TRANSIENT_FAILURE }
      end).to be(true)

      expect(GRPC::Core::LbPolicyState.aggregate([a, b])).to eq(States::TRANSIENT_FAILURE)
    end

    it 'is IDLE, not TRANSIENT_FAILURE, while one address is untried' do
      failed = fake_subchannel(:fail)
      untried = fake_subchannel(:ready)
      failed.maybe_connect
      expect(wait_until { failed.state == States::TRANSIENT_FAILURE }).to be(true)

      expect(GRPC::Core::LbPolicyState.aggregate([failed, untried])).to eq(States::IDLE)
    end
  end

  describe GRPC::Core::PickFirstPolicy do
    it 'stays on the first address once it is ready' do
      first = fake_subchannel(:ready)
      second = fake_subchannel(:ready)
      policy = described_class.new([first, second])

      policy.maybe_connect
      expect(wait_until { first.alive? }).to be(true)

      expect(policy.pick).to equal(first)
      expect(second.state).to eq(States::IDLE)
    end

    it 'falls past a dead address to a live one behind it' do
      dead = fake_subchannel(:fail)
      live = fake_subchannel(:ready)
      policy = described_class.new([dead, live])

      policy.maybe_connect
      expect(wait_until { dead.state == States::TRANSIENT_FAILURE }).to be(true)
      policy.maybe_connect
      expect(wait_until { live.alive? }).to be(true)

      expect(policy.pick).to equal(live)
    end
  end

  describe GRPC::Core::RoundRobinPolicy do
    it 'rotates calls across every ready subchannel' do
      a = fake_subchannel(:ready)
      b = fake_subchannel(:ready)
      policy = described_class.new([a, b])

      policy.maybe_connect
      expect(wait_until { a.alive? && b.alive? }).to be(true)

      picks = Array.new(4) { policy.pick }
      expect(picks.uniq).to match_array([a, b])
    end

    it 'skips a failed subchannel and keeps using the live one' do
      dead = fake_subchannel(:fail)
      live = fake_subchannel(:ready)
      policy = described_class.new([dead, live])

      policy.maybe_connect
      expect(wait_until { live.alive? && dead.state == States::TRANSIENT_FAILURE }).to be(true)

      expect(Array.new(3) { policy.pick }.uniq).to eq([live])
    end
  end

  describe 'a channel choosing an lb policy' do
    it 'rejects a name it does not implement' do
      expect do
        GRPC::Core::Channel.new('localhost:1', { 'grpc.lb_policy_name' => 'grpclb' },
                                :this_channel_is_insecure)
      end.to raise_error(ArgumentError, /grpc.lb_policy_name/)
    end

    it 'defaults to pick_first' do
      ch = GRPC::Core::Channel.new('localhost:1', {}, :this_channel_is_insecure)
      expect(ch.instance_variable_get(:@lb_policy_name)).to eq('pick_first')
      ch.close
    end
  end

  describe 'end to end through a Channel' do
    it 'pick_first falls past a dead address to a live one' do
      build_rpc_server
      run_services_on_server(@server, services: [EchoService]) do
        stub_addresses(dead_target, AddressTarget.new(:tcp, '127.0.0.1', @port, nil))
        stub = build_insecure_stub(EchoStub, host: 'multi-pf.example:443')

        reply = stub.an_rpc(EchoMsg.new(msg: 'past the dead one'), deadline: Time.now + 5)

        expect(reply.msg).to eq('past the dead one')
      end
    end

    it 'round_robin spreads calls across two live in-process servers' do
      servers = Array.new(2) { build_counting_server }
      begin
        stub_addresses(*servers.map { |s| AddressTarget.new(:tcp, '127.0.0.1', s[:port], nil) })
        channel_args = { 'grpc.lb_policy_name' => 'round_robin' }
        stub = build_insecure_stub(EchoStub, host: 'multi-rr.example:443',
                                             opts: { channel_args: channel_args })

        # Warm up: round_robin only rotates across subchannels that are
        # already READY, so give both a chance to finish connecting before
        # the calls that are actually asserted on.
        8.times { stub.an_rpc(EchoMsg.new(msg: 'warm'), deadline: Time.now + 5) }
        counts_before = servers.map { |s| s[:count].call }

        20.times { stub.an_rpc(EchoMsg.new(msg: 'rr'), deadline: Time.now + 5) }

        counts_after = servers.map { |s| s[:count].call }
        deltas = counts_after.zip(counts_before).map { |after, before| after - before }
        expect(deltas.all?(&:positive?)).to be(true)
      ensure
        servers.each do |s|
          s[:server].stop
          s[:thread].join
        end
      end
    end
  end

  # A second RpcServer with its own call counter, independent of the
  # @server/@port the Helpers module manages, so round_robin has two
  # distinct live addresses to spread calls across.
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
