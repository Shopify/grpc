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

# Counts and time-stamps the PINGs a connection sends, and separately counts
# real traffic through #send_headers/#send_data/#send_trailers, the same
# surface a real Session exposes -- so Connection's own policing
# (grpc.http2.max_pings_without_data, grpc.http2.min_time_between_pings_ms)
# can be exercised without a socket underneath it.
class PingPolicingSession
  attr_reader :ping_times, :data_frames_sent

  def initialize
    @ping_times = []
    @data_frames_sent = 0
    @mu = Mutex.new
  end

  def ping
    @mu.synchronize { @ping_times << Process.clock_gettime(Process::CLOCK_MONOTONIC) }
  end

  def send_headers(*)
    @mu.synchronize { @data_frames_sent += 1 }
  end

  def send_data(*)
    @mu.synchronize { @data_frames_sent += 1 }
  end

  def send_trailers(*)
    @mu.synchronize { @data_frames_sent += 1 }
  end

  def connect; end
  def receive; end
  def shutdown; end

  # Connection#close asks the session whether its reader and writer threads
  # ever started, so it knows whether a queued shutdown will actually drain.
  # These fakes have no threads, so the socket path is the honest answer.
  def running?
    false
  end

  def new_stream
    1
  end
end

# grpc.http2.max_pings_without_data and grpc.http2.min_time_between_pings_ms:
# both were unimplemented, so a connection configured with a short
# grpc.keepalive_time_ms and nothing else pinged an idle peer forever,
# exactly the traffic pattern that gets a well-behaved client banned by a
# strict proxy or load balancer.
describe 'sending PINGs (grpc.http2.max_pings_without_data, grpc.http2.min_time_between_pings_ms)' do
  include GRPC::Spec::Helpers

  let(:session) { PingPolicingSession.new }

  def build_connection(**opts)
    conn = GRPC::Core::Connection.new(
      StringIO.new, peer: 'test', client: true,
                    max_receive_message_length: 1 << 20, **opts)
    conn.instance_variable_set(:@session, session)
    conn
  end

  after(:each) { @conn&.close }

  it 'stops sending pings once max_pings_without_data is reached with nothing sent' do
    @conn = build_connection(keepalive_time: 0.01, keepalive_permit_without_calls: true,
                             max_pings_without_data: 2)
    @conn.start
    sleep 0.15
    expect(session.ping_times.size).to eq(2)
  end

  it 'resumes pinging once data flows again' do
    @conn = build_connection(keepalive_time: 0.01, keepalive_permit_without_calls: true,
                             max_pings_without_data: 2)
    @conn.start
    sleep 0.1
    expect(session.ping_times.size).to eq(2)

    session.send_headers(1, [], has_body: true) # simulate a real RPC's HEADERS
    sleep 0.1
    expect(session.ping_times.size).to be > 2
  end

  it 'treats 0 as unlimited' do
    @conn = build_connection(keepalive_time: 0.01, keepalive_permit_without_calls: true,
                             max_pings_without_data: 0)
    @conn.start
    sleep 0.1
    expect(session.ping_times.size).to be > 5
  end

  it 'honours the minimum spacing between its own pings even under a much faster keepalive_time' do
    @conn = build_connection(keepalive_time: 0.01, keepalive_permit_without_calls: true,
                             max_pings_without_data: 0,
                             min_time_between_pings: 0.08)
    @conn.start
    sleep 0.3
    expect(session.ping_times.size).to be >= 2
    gaps = session.ping_times.each_cons(2).map { |a, b| b - a }
    expect(gaps).to all(be >= 0.07) # a hair under the 0.08s floor for scheduler jitter
  end
end

# grpc.http2.max_ping_strikes: an unbounded stream of PINGs from a peer,
# nothing sent on this side to explain them, used to be answered forever.
# This is a receiver policy, so it lives in Session#handle_ping rather than
# Connection; driven directly the way flow_control_spec.rb drives internal
# frame handlers, with the clock forged where the real interval (minutes)
# would make the test itself the slow part.
describe 'receiving PINGs (grpc.http2.max_ping_strikes)' do
  let(:queue) { [] }

  def build_session(max_ping_strikes: 2)
    s = GRPC::Core::Http2::Kantan::H2::Session.allocate
    s.instance_variable_set(:@write_queue, queue)
    s.instance_variable_set(:@max_ping_strikes, max_ping_strikes)
    s.instance_variable_set(:@ping_strikes, 0)
    s.instance_variable_set(:@last_ping_received_at, nil)
    s.instance_variable_set(:@data_frames_sent, 0)
    s.instance_variable_set(:@data_frames_sent_at_last_ping_strike_check, 0)
    s
  end

  def deliver_ping(session)
    session.send(:handle_ping, StringIO.new("\x00" * 8), 8, 0x0, 0)
  end

  it 'raises EnhanceYourCalm with ENHANCE_YOUR_CALM once a flooding peer exceeds max_ping_strikes' do
    session = build_session(max_ping_strikes: 2)
    3.times { expect { deliver_ping(session) }.to_not raise_error }
    expect { deliver_ping(session) }.to raise_error(GRPC::Core::Http2::Kantan::Errors::EnhanceYourCalm) do |e|
      # read_loop turns this into `@write_queue << [:goaway, e.error_code]`
      # followed by shutdown; the error_code is what makes that GOAWAY say
      # ENHANCE_YOUR_CALM instead of a generic protocol error.
      expect(e.error_code).to eq(0xb)
    end
  end

  it 'treats 0 as unlimited: no amount of flooding raises' do
    session = build_session(max_ping_strikes: 0)
    10.times { expect { deliver_ping(session) }.to_not raise_error }
    expect(queue.map(&:first)).to_not include(:goaway)
  end

  it 'does not strike pings spaced further apart than the abuse window' do
    session = build_session(max_ping_strikes: 1)
    4.times do
      session.instance_variable_set(
        :@last_ping_received_at,
        Process.clock_gettime(Process::CLOCK_MONOTONIC) -
          (GRPC::Core::Http2::Kantan::H2::Session::PING_STRIKE_INTERVAL + 1))
      expect { deliver_ping(session) }.to_not raise_error
    end
    expect(session.instance_variable_get(:@ping_strikes)).to eq(0)
  end

  it 'does not strike pings that arrive after this side has sent data' do
    session = build_session(max_ping_strikes: 5)
    deliver_ping(session) # baseline: establishes @last_ping_received_at
    deliver_ping(session) # rapid follow-up: one strike
    expect(session.instance_variable_get(:@ping_strikes)).to eq(1)

    session.instance_variable_set(:@data_frames_sent, 1) # a real frame went out
    deliver_ping(session)
    expect(session.instance_variable_get(:@ping_strikes)).to eq(0)
  end
end
