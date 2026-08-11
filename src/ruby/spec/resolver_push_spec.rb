# frozen_string_literal: true

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

# A healthy Channel used to resolve its target exactly once: nothing asked
# again while the addresses it already had kept working, so a control-plane
# push that swapped in a same-cluster, reachable EDS update never moved any
# traffic. These specs drive Channel#apply_resolver_push the same way
# XdsClient::AdsConnection actually does -- through the block
# Transport.watch_addresses is given -- without a real management server,
# and prove the reconciliation itself: added/removed addresses take/lose
# traffic, a kept address keeps its Subchannel (and Connection) object, and
# the subscription plus its thread are gone once the Channel is destroyed.
# Records the block Transport.watch_addresses was given (the same one
# XdsClient::AdsConnection#watch_endpoints would eventually call from its
# own thread) so a spec can call it directly to simulate a push, plus how
# many times the handle it returned was cancelled.
ResolverWatch = Struct.new(:push_block, :cancel_count) do
  def push(addresses)
    push_block.call(addresses)
  end
end

describe 'a resolver pushing an address update into a live Channel' do
  include GRPC::Spec::Helpers

  def stub_watch
    watch = ResolverWatch.new(nil, 0)
    handle = double('resolver watch handle')
    allow(handle).to receive(:cancel) { watch.cancel_count += 1 }
    allow(GRPC::Core::Transport).to receive(:watch_addresses) do |_target, _args, &block|
      watch.push_block = block
      handle
    end
    watch
  end

  # Makes every channel built while the block runs resolve @parsed_target to
  # +targets+, standing in for the DNS/xDS answer a real resolver would give.
  def stub_addresses(*targets)
    allow(GRPC::Core::Transport).to receive(:resolve_addresses) do |target|
      target.addresses = targets
    end
  end

  def address_for(server)
    GRPC::Core::Transport::Target.new(:tcp, '127.0.0.1', server[:port], nil)
  end

  # A second (and third) RpcServer with its own call counter, independent of
  # the @server/@port GRPC::Spec::Helpers manages, so a push can add/remove
  # a live address distinct from the channel's first one.
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

  def stop_server(server)
    server[:server].stop
    server[:thread].join
  end

  # Polls instead of sleeping a fixed amount, so a spec waiting for a
  # background effect (a subchannel connecting, a thread exiting) is both
  # fast on a healthy run and not flaky under load.
  def wait_until(timeout = 2.0)
    deadline = Time.now + timeout
    loop do
      return true if yield
      return false if Time.now > deadline
      sleep 0.005
    end
  end

  it 'makes a newly pushed address usable' do
    a = build_counting_server
    b = build_counting_server
    begin
      watch = stub_watch
      stub_addresses(address_for(a))
      channel_args = { 'grpc.lb_policy_name' => 'round_robin' }
      stub = build_insecure_stub(EchoStub, host: 'resolver-push-add.example:443',
                                           opts: { channel_args: channel_args })
      stub.an_rpc(EchoMsg.new(msg: 'warm'), deadline: Time.now + 5)

      watch.push([address_for(a), address_for(b)])
      # round_robin only rotates across subchannels already READY, so keep
      # issuing calls -- exactly what real traffic would do -- while b's
      # freshly pushed Subchannel finishes connecting, rather than a bare
      # sleep that could simply outrun a slow CI dial.
      before = b[:count].call
      wait_until(3.0) do
        stub.an_rpc(EchoMsg.new(msg: 'poke'), deadline: Time.now + 5)
        b[:count].call > before
      end

      expect(b[:count].call).to be > before
    ensure
      stop_server(a)
      stop_server(b)
    end
  end

  it 'stops picking an address a later push removes' do
    a = build_counting_server
    b = build_counting_server
    begin
      watch = stub_watch
      stub_addresses(address_for(a), address_for(b))
      channel_args = { 'grpc.lb_policy_name' => 'round_robin' }
      stub = build_insecure_stub(EchoStub, host: 'resolver-push-remove.example:443',
                                           opts: { channel_args: channel_args })
      8.times { stub.an_rpc(EchoMsg.new(msg: 'warm'), deadline: Time.now + 5) }

      watch.push([address_for(a)])
      b_before = b[:count].call
      a_before = a[:count].call
      12.times { stub.an_rpc(EchoMsg.new(msg: 'after removal'), deadline: Time.now + 5) }

      expect(b[:count].call).to eq(b_before)
      expect(a[:count].call).to be > a_before
    ensure
      stop_server(a)
      stop_server(b)
    end
  end

  it 'keeps the same Subchannel (and live Connection) for an address present before and after a push' do
    a = build_counting_server
    b = build_counting_server
    c = build_counting_server
    begin
      watch = stub_watch
      stub_addresses(address_for(a), address_for(b))
      channel_args = { 'grpc.lb_policy_name' => 'round_robin' }
      stub = build_insecure_stub(EchoStub, host: 'resolver-push-identity.example:443',
                                           opts: { channel_args: channel_args })
      8.times { stub.an_rpc(EchoMsg.new(msg: 'warm'), deadline: Time.now + 5) }

      channel = stub.instance_variable_get(:@ch)
      before = channel.instance_variable_get(:@subchannels)
      subchannel_for_a = before.find { |sc| sc.address.port == a[:port] }
      connection_for_a = subchannel_for_a.connection
      expect(subchannel_for_a).not_to be_nil
      expect(connection_for_a).not_to be_nil

      watch.push([address_for(a), address_for(c)])

      after = channel.instance_variable_get(:@subchannels)
      kept = after.find { |sc| sc.address.port == a[:port] }

      expect(kept).to equal(subchannel_for_a)
      expect(kept.connection).to equal(connection_for_a)
      expect(after.map { |sc| sc.address.port }).not_to include(b[:port])
    ensure
      stop_server(a)
      stop_server(b)
      stop_server(c)
    end
  end

  it 'cancels the subscription and leaves no thread behind when the channel is destroyed' do
    a = build_counting_server
    begin
      watch = stub_watch
      stub_addresses(address_for(a))
      channel = GRPC::Core::Channel.new('resolver-push-destroy.example:443', {}, :this_channel_is_insecure)
      channel.connectivity_state(true)
      wait_until { !channel.instance_variable_get(:@resolve_thread)&.alive? }
      resolve_thread = channel.instance_variable_get(:@resolve_thread)

      channel.destroy

      expect(watch.cancel_count).to eq(1)
      expect(resolve_thread.alive?).to be(false)
      expect(channel.instance_variable_get(:@resolver_watch)).to be_nil
    ensure
      stop_server(a)
    end
  end
end
