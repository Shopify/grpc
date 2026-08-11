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
require 'socket'

# Named apart from flow_control_spec.rb's own Session/Kantan/H2_PREFACE
# top-level constants and SilentHandler class: this file is loaded into the
# same process as every other spec, and redefining those would either warn
# or, load-order permitting, collide outright.
BdpSession = GRPC::Core::Http2::Kantan::H2::Session
BdpKantan = GRPC::Core::Http2::Kantan
BDP_H2_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".b
BDP_DATA_CHUNK = 16_384 # the largest frame this endpoint accepts by default

class BdpSilentHandler < BdpKantan::Handler
  def on_request(_stream); end
end

# grpc.http2.bdp_probe, grpc.http2.lookahead_bytes, grpc.http2.max_frame_size
# and grpc.http2.write_buffer_size, exercised the way flow_control_spec.rb and
# ping_policing_spec.rb already exercise Session and Connection: real sockets
# and hand-built frames underneath, so the assertions are about what actually
# went out over HTTP/2, not about a mock standing in for it.
describe 'BDP probing and dynamic flow-control windows' do
  def frame(type, flags, sid, payload = ''.b)
    [(payload.bytesize << 8) | type, flags, sid].pack('NCN') + payload
  end

  def open_stream(peer, stream_id = 1)
    headers = BdpKantan::H2::HPACK.new.encode(
      [[':method', 'POST'], [':scheme', 'http'],
       [':path', '/x'], [':authority', 'h']])
    peer.write frame(0x1, 0x04, stream_id, headers)
  end

  def send_data(peer, stream_id, bytes)
    payload = ('d' * BDP_DATA_CHUNK).b
    sent = 0
    while sent < bytes
      peer.write frame(0x0, 0, stream_id, payload)
      sent += BDP_DATA_CHUNK
    end
    sent
  end

  # Drains whatever is already on the wire: sums connection- and
  # stream-level WINDOW_UPDATE increments into +window_updates+, and answers
  # every fresh (non-ACK) PING with an ACK of its exact payload -- appending
  # that payload to +ping_payloads+ first, so a caller can tell a BDP probe's
  # tagged payload apart from an ordinary one after the fact.
  def service_frames(sock, window_updates, ping_payloads)
    loop do
      header = sock.read_nonblock(9, exception: false)
      return if header == :wait_readable || header.nil? || header.bytesize < 9
      len_type, flags, sid = header.unpack('NCN')
      len = len_type >> 8
      type = len_type & 0xFF
      sid &= 0x7FFF_FFFF
      body = len.positive? ? sock.read(len) : ''.b
      case type
      when 0x8
        window_updates[sid] += body.unpack1('N')
      when 0x6
        next unless flags.even? # ignore ACKs of anything this peer script sent
        ping_payloads << body
        sock.write frame(0x6, 0x1, 0, body)
      end
    end
  rescue IO::WaitReadable, IOError
    nil
  end

  def socket_pair
    server_sock, peer = Socket.pair(:UNIX, :STREAM)
    [server_sock, peer].each do |sock|
      sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, 1 << 24)
      sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 1 << 24)
    end
    [server_sock, peer]
  end

  describe 'grpc.http2.bdp_probe and grpc.http2.lookahead_bytes' do
    it 'grows the receive window toward the estimated bandwidth-delay-product, capped at the lookahead ceiling' do
      server_sock, peer = socket_pair
      ceiling = BdpSession::RECEIVE_WINDOW + 3 * BdpSession::WINDOW_UPDATE_THRESHOLD
      session = BdpSession.new(server_sock, handler: BdpSilentHandler.new,
                                            bdp_probe: true, lookahead_bytes: ceiling)
      begin
        peer.write BDP_H2_PREFACE
        peer.write frame(0x4, 0, 0)
        session.receive
        open_stream(peer)
        sleep 0.1

        # Comfortably more than the ceiling however early the probe's
        # snapshot lands relative to this burst, so growth is forced to hit
        # the cap rather than merely move toward it.
        sent = send_data(peer, 1, BdpSession::RECEIVE_WINDOW + 6 * BdpSession::WINDOW_UPDATE_THRESHOLD)
        sleep 0.3

        window_updates = Hash.new(0)
        pings = []
        service_frames(peer, window_updates, pings)
        expect(pings).not_to be_empty # the burst had to have armed a probe
        sleep 0.2
        service_frames(peer, window_updates, pings)

        expect(session.instance_variable_get(:@bdp_window_target)).to eq(ceiling)

        # A second burst must not push the target past the ceiling, and must
        # not arm another probe now that the ceiling is already reached --
        # otherwise this side would keep pinging a link that has nothing
        # left to learn.
        pings.clear
        send_data(peer, 1, BdpSession::WINDOW_UPDATE_THRESHOLD * 2)
        sleep 0.3
        service_frames(peer, window_updates, pings)

        expect(pings).to be_empty
        expect(session.instance_variable_get(:@bdp_window_target)).to eq(ceiling)
        expect(sent).to be > 0
      ensure
        begin
          session&.shutdown
        rescue StandardError
          nil
        end
        begin
          peer&.close
        rescue StandardError
          nil
        end
      end
    end

    it 'leaves the receive window fixed when bdp_probe is disabled' do
      server_sock, peer = socket_pair
      session = BdpSession.new(server_sock, handler: BdpSilentHandler.new,
                                            bdp_probe: false, lookahead_bytes: 8 * (1 << 20))
      begin
        peer.write BDP_H2_PREFACE
        peer.write frame(0x4, 0, 0)
        session.receive
        open_stream(peer)
        sleep 0.1

        send_data(peer, 1, BdpSession::RECEIVE_WINDOW + 6 * BdpSession::WINDOW_UPDATE_THRESHOLD)
        sleep 0.3

        window_updates = Hash.new(0)
        pings = []
        service_frames(peer, window_updates, pings)
        sleep 0.2
        service_frames(peer, window_updates, pings)

        expect(pings).to be_empty # no probe was ever armed
        expect(session.instance_variable_get(:@bdp_window_target)).to eq(BdpSession::RECEIVE_WINDOW)
      ensure
        begin
          session&.shutdown
        rescue StandardError
          nil
        end
        begin
          peer&.close
        rescue StandardError
          nil
        end
      end
    end
  end

  describe 'grpc.http2.max_frame_size' do
    def read_settings(peer)
      header = peer.read_nonblock(9, exception: false)
      return nil if header == :wait_readable || header.nil?
      len_type, = header.unpack('NCN')
      len = len_type >> 8
      body = len.positive? ? peer.read(len) : ''.b
      (len / 6).times.each_with_object({}) do |i, acc|
        ident, value = body[i * 6, 6].unpack('nN')
        acc[ident] = value
      end
    end

    it 'is advertised in this side\'s own SETTINGS' do
      server_sock, peer = socket_pair
      session = BdpSession.new(server_sock, handler: BdpSilentHandler.new, max_frame_size: 65_536)
      begin
        peer.write BDP_H2_PREFACE
        peer.write frame(0x4, 0, 0)
        session.receive
        sleep 0.05
        settings = read_settings(peer)
        expect(settings[0x5]).to eq(65_536) # SETTINGS_MAX_FRAME_SIZE
      ensure
        begin
          session&.shutdown
        rescue StandardError
          nil
        end
        begin
          peer&.close
        rescue StandardError
          nil
        end
      end
    end

    it 'is absent from SETTINGS when left unset, as before this feature existed' do
      server_sock, peer = socket_pair
      session = BdpSession.new(server_sock, handler: BdpSilentHandler.new)
      begin
        peer.write BDP_H2_PREFACE
        peer.write frame(0x4, 0, 0)
        session.receive
        sleep 0.05
        settings = read_settings(peer)
        expect(settings).not_to have_key(0x5)
      ensure
        begin
          session&.shutdown
        rescue StandardError
          nil
        end
        begin
          peer&.close
        rescue StandardError
          nil
        end
      end
    end

    it 'rejects a value outside the RFC 7540 range' do
      server_sock, = socket_pair
      expect do
        BdpSession.new(server_sock, handler: BdpSilentHandler.new, max_frame_size: 1024)
      end.to raise_error(ArgumentError, /max_frame_size/)
    end
  end

  describe 'grpc.http2.write_buffer_size' do
    it 'is carried onto the Session that a Connection builds' do
      session = BdpSession.new(StringIO.new, handler: BdpSilentHandler.new, write_buffer_size: 8192)
      expect(session.instance_variable_get(:@write_buffer_size)).to eq(8192)
    end

    it 'defaults to WRITE_BUFFER_SIZE when unset' do
      session = BdpSession.new(StringIO.new, handler: BdpSilentHandler.new)
      expect(session.instance_variable_get(:@write_buffer_size)).to eq(BdpSession::WRITE_BUFFER_SIZE)
    end
  end

  # grpc.http2.max_pings_without_data throttles how many *keepalive* PINGs
  # Connection sends without real traffic to justify them (ping_policing_spec
  # covers that in isolation). A BDP probe is sent by Session directly, not
  # through Connection#send_keepalive_ping, so it must neither be throttled
  # by that counter nor advance it -- proved here by tagging every PING this
  # side sends (top bit of the payload) and counting each kind separately
  # while a real Connection both keeps a tight keepalive budget and probes a
  # sustained inbound stream.
  describe 'BDP probing alongside grpc.http2.max_pings_without_data' do
    it 'keeps probing after the keepalive ping budget is exhausted' do
      server_sock, peer = socket_pair
      conn = GRPC::Core::Connection.new(
        server_sock, peer: 'test', client: false,
                     max_receive_message_length: 1 << 20,
                     keepalive_time: 0.02, keepalive_permit_without_calls: true,
                     max_pings_without_data: 2,
                     bdp_probe: true, lookahead_bytes: 8 * (1 << 20))
      begin
        peer.write BDP_H2_PREFACE
        peer.write frame(0x4, 0, 0)
        conn.start
        sleep 0.05
        open_stream(peer)
        sleep 0.05

        window_updates = Hash.new(0)
        pings = []
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.0
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          send_data(peer, 1, BdpSession::WINDOW_UPDATE_THRESHOLD)
          service_frames(peer, window_updates, pings)
          sleep 0.02
        end
        service_frames(peer, window_updates, pings)

        bdp_flag = 1 << 63
        bdp_pings = pings.count { |p| !(p.unpack1('Q>') & bdp_flag).zero? }
        keepalive_pings = pings.size - bdp_pings

        # Nothing this connection sends ever counts as "data" from
        # Connection's point of view (it only receives), so its own
        # keepalive ping budget is exhausted at exactly the configured
        # limit -- matching ping_policing_spec's own assertion for the same
        # scenario without BDP probing in the mix.
        expect(keepalive_pings).to eq(2)
        # The sustained inbound stream must keep arming BDP probes long
        # after that budget is gone.
        expect(bdp_pings).to be > 2
      ensure
        begin
          conn&.close
        rescue StandardError
          nil
        end
        begin
          peer&.close
        rescue StandardError
          nil
        end
      end
    end
  end

  # ChannelArgs::HONOURED accepting these four is necessary but not
  # sufficient -- rejected_config_spec.rb already covers a plain reject/
  # accept round trip for every honoured argument. This is the wiring from
  # there through Channel and Server to the Connection that actually opens
  # the socket: a real RPC over a channel configured with all four args at
  # once, on both ends, proving neither Channel nor Server drops them before
  # Connection.new.
  describe 'the channel arguments' do
    include GRPC::Spec::Helpers

    it 'carries all four into a live channel and server' do
      http2_args = {
        'grpc.http2.bdp_probe' => 1,
        'grpc.http2.lookahead_bytes' => 2 * (1 << 20),
        'grpc.http2.max_frame_size' => 32_768,
        'grpc.http2.write_buffer_size' => 32_768
      }
      build_rpc_server(server_opts: { server_args: http2_args })
      run_services_on_server(@server, services: [EchoService]) do
        stub = build_insecure_stub(EchoStub, opts: { channel_args: http2_args })
        expect(stub.an_rpc(EchoMsg.new(msg: 'ok')).msg).to eq('ok')
      end
    end
  end
end
