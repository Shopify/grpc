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

# Three server-side controls that were previously refused outright:
#
# * grpc.server.max_pending_requests bounds the queue of RPCs accepted but
#   not yet handed to #request_call, instead of letting it grow without
#   bound under load.
# * grpc.server_handshake_timeout_ms bounds how long a connection may sit
#   accepted but never driven to a completed HTTP/2 handshake, instead of
#   holding a thread and a socket forever.
# * grpc.expand_wildcard_addrs binds one socket per concrete local address
#   instead of the single wildcard socket, when asked to.
describe 'server-side load and handshake controls' do
  # A stream opened straight through GRPC::Core::Call, bypassing the
  # generic-service/stub layer entirely so the test controls exactly when
  # (and whether) #request_call ever drains the server's pending queue.
  def open_stream(channel, method, deadline: Time.now + 5)
    call = channel.create_call(nil, nil, method, nil, deadline)
    call.run_batch(
      GRPC::Core::CallOps::SEND_INITIAL_METADATA => {},
      GRPC::Core::CallOps::SEND_CLOSE_FROM_CLIENT => nil)
    call
  end

  def client_status(call)
    call.run_batch(
      GRPC::Core::CallOps::RECV_INITIAL_METADATA => nil,
      GRPC::Core::CallOps::RECV_STATUS_ON_CLIENT => nil
    ).status
  end

  # Answers a request pulled off #request_call with a plain OK, the way a
  # handler that finished normally would, so the client's own
  # RECV_STATUS_ON_CLIENT batch (already issued by the caller) resolves.
  def answer_ok(rpc)
    rpc.call.run_batch(
      GRPC::Core::CallOps::SEND_STATUS_FROM_SERVER => Struct::Status.new(
        GRPC::Core::StatusCodes::OK, 'OK'))
  end

  describe 'grpc.server.max_pending_requests' do
    after(:each) { @server&.close }

    it 'sheds a request over the limit with RESOURCE_EXHAUSTED, and recovers once the queue drains' do
      @server = GRPC::Core::Server.new('grpc.server.max_pending_requests' => 2)
      port = @server.add_http2_port('0.0.0.0:0', :this_port_is_insecure)
      @server.start
      channel = GRPC::Core::Channel.new("0.0.0.0:#{port}", nil, :this_channel_is_insecure)

      # Two RPCs fill the queue; #request_call never runs, so nothing drains
      # it while the next two are opened.
      within_limit = Array.new(2) { |i| open_stream(channel, "queued_#{i}") }

      # A request over the limit must be shed with a status the client can
      # act on, not left to time out or find the connection merely dropped.
      over_limit = Array.new(2) { |i| open_stream(channel, "shed_#{i}") }
      over_limit.each do |call|
        status = client_status(call)
        expect(status.code).to eq(GRPC::Core::StatusCodes::RESOURCE_EXHAUSTED)
        expect(status.details).to match(/grpc.server.max_pending_requests/)
      end

      # Draining the two within the limit through #request_call frees the
      # queue -- shedding the excess must not be permanent.
      within_limit.each_with_index do |call, i|
        rpc = @server.request_call
        expect(rpc.method).to eq("queued_#{i}")
        answer_ok(rpc)
        expect(client_status(call).code).to eq(GRPC::Core::StatusCodes::OK)
      end
    end

    it 'queues a request under the limit once the backlog has drained' do
      @server = GRPC::Core::Server.new('grpc.server.max_pending_requests' => 1)
      port = @server.add_http2_port('0.0.0.0:0', :this_port_is_insecure)
      @server.start
      channel = GRPC::Core::Channel.new("0.0.0.0:#{port}", nil, :this_channel_is_insecure)

      filler = open_stream(channel, 'filler')
      shed = open_stream(channel, 'shed')
      expect(client_status(shed).code).to eq(GRPC::Core::StatusCodes::RESOURCE_EXHAUSTED)

      rpc = @server.request_call
      answer_ok(rpc)
      expect(client_status(filler).code).to eq(GRPC::Core::StatusCodes::OK)

      recovered = open_stream(channel, 'recovered')
      recovered_rpc = @server.request_call
      expect(recovered_rpc.method).to eq('recovered')
      answer_ok(recovered_rpc)
      expect(client_status(recovered).code).to eq(GRPC::Core::StatusCodes::OK)
    end
  end

  describe 'grpc.server_handshake_timeout_ms' do
    after(:each) { @server&.close }

    it 'closes a peer that never sends the connection preface, without leaking a thread or socket' do
      @server = GRPC::Core::Server.new('grpc.server_handshake_timeout_ms' => 30)
      port = @server.add_http2_port('0.0.0.0:0', :this_port_is_insecure)
      @server.start

      # Threads that exist before the peer even connects are none of this
      # test's business (RSpec's own machinery, straggler threads from a
      # previous example not yet reaped); only threads spawned to service
      # *this* connection matter.
      baseline = Thread.list.dup

      peer = TCPSocket.new('127.0.0.1', port)
      # Never sends anything -- no preface, no SETTINGS, nothing.

      # Captured while the connection thread (and the watchdog it starts)
      # are still alive -- a dead, unjoined thread drops out of
      # Thread.list, so waiting until after the peer closes to look would
      # just find nothing and prove nothing.
      spawn_deadline = Time.now + 1
      new_threads = []
      until new_threads.any? || Time.now > spawn_deadline
        new_threads = Thread.list - baseline
        sleep 0.005 if new_threads.empty?
      end
      expect(new_threads).to_not be_empty # sanity: something was spawned

      limit = Time.now + 2
      closed = false
      until closed || Time.now > limit
        closed = begin
          peer.read_nonblock(1)
          false
        rescue EOFError
          true
        rescue IO::WaitReadable
          false
        end
        sleep 0.005 unless closed
      end
      expect(closed).to be true

      # The connection thread spawned to service +peer+, and the watchdog
      # thread that timed it out, must both have exited -- not merely the
      # socket having been closed out from under a still-running thread.
      reap_deadline = Time.now + 1
      sleep 0.005 while new_threads.any?(&:alive?) && Time.now < reap_deadline
      expect(new_threads.map(&:alive?)).to eq([false] * new_threads.size)
    ensure
      peer&.close
    end

    it 'leaves a connection that completes the handshake in time untouched' do
      @server = GRPC::Core::Server.new('grpc.server_handshake_timeout_ms' => 50)
      port = @server.add_http2_port('0.0.0.0:0', :this_port_is_insecure)
      @server.start
      channel = GRPC::Core::Channel.new("0.0.0.0:#{port}", nil, :this_channel_is_insecure)

      call = open_stream(channel, 'in_time')
      sleep 0.1 # past the handshake timeout, to prove it did not fire
      rpc = @server.request_call
      expect(rpc.method).to eq('in_time')
      answer_ok(rpc)
      expect(client_status(call).code).to eq(GRPC::Core::StatusCodes::OK)
    end
  end

  describe 'grpc.expand_wildcard_addrs' do
    it 'keeps the single wildcard socket by default' do
      listeners = GRPC::Core::Transport.listen('0.0.0.0:0')
      expect(listeners.size).to eq(1)
    ensure
      # rubocop:disable Style/HashEachMethods -- an Array of [socket, port]
      # pairs, not a Hash.
      listeners&.each { |listener, _port| listener.close }
      # rubocop:enable Style/HashEachMethods
    end

    it 'binds one socket per concrete local address when enabled' do
      listeners = GRPC::Core::Transport.listen('0.0.0.0:0', expand_wildcard_addrs: true)
      expect(listeners.size).to be > 1
      # Every socket shares the port the first one picked.
      expect(listeners.map(&:last).uniq).to eq([listeners.first.last])
    ensure
      # rubocop:disable Style/HashEachMethods -- an Array of [socket, port]
      # pairs, not a Hash.
      listeners&.each { |listener, _port| listener.close }
      # rubocop:enable Style/HashEachMethods
    end

    it 'does not expand a non-wildcard host even when enabled' do
      listeners = GRPC::Core::Transport.listen('127.0.0.1:0', expand_wildcard_addrs: true)
      expect(listeners.size).to eq(1)
    ensure
      # rubocop:disable Style/HashEachMethods -- an Array of [socket, port]
      # pairs, not a Hash.
      listeners&.each { |listener, _port| listener.close }
      # rubocop:enable Style/HashEachMethods
    end

    it 'accepts a connection on more than one address once expanded' do
      server = GRPC::Core::Server.new('grpc.expand_wildcard_addrs' => 1)
      port = server.add_http2_port('0.0.0.0:0', :this_port_is_insecure)
      server.start
      begin
        %w[127.0.0.1].each do |host|
          channel = GRPC::Core::Channel.new("#{host}:#{port}", nil, :this_channel_is_insecure)
          call = open_stream(channel, 'via_expanded_addr')
          rpc = server.request_call
          expect(rpc.method).to eq('via_expanded_addr')
          answer_ok(rpc)
          expect(client_status(call).code).to eq(GRPC::Core::StatusCodes::OK)
        end
      ensure
        server.close
      end
    end
  end

  describe GRPC::Core::ChannelArgs do
    it 'lists the three new arguments in HONOURED' do
      expect(described_class::HONOURED).to include(
        'grpc.server.max_pending_requests',
        'grpc.server_handshake_timeout_ms',
        'grpc.expand_wildcard_addrs')
    end

    it 'keeps HONOURED sorted' do
      expect(described_class::HONOURED).to eq(described_class::HONOURED.sort)
    end

    it 'accepts every new argument without raising' do
      expect do
        described_class.normalize(
          'grpc.server.max_pending_requests' => 10,
          'grpc.server_handshake_timeout_ms' => 30,
          'grpc.expand_wildcard_addrs' => 1)
      end.to_not raise_error
    end
  end
end
