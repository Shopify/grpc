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

Session = GRPC::Core::Http2::Kantan::H2::Session
Kantan = GRPC::Core::Http2::Kantan
H2_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".b
DATA_CHUNK = 16_384 # the largest frame this endpoint accepts

# Ignores everything; the point is what the session does underneath.
class SilentHandler < Kantan::Handler
  def on_request(_stream); end
end

# Received bytes are acknowledged in blocks rather than per DATA frame. Any
# byte this endpoint declines to deliver still has to be returned, or the
# window drains and the connection stalls with no error anywhere.
describe 'HTTP/2 flow control accounting' do
  describe Session, '#credit_connection_window' do
    before(:each) do
      @session = Session.allocate
      @queue = []
      @session.instance_variable_set(:@connection_unacked, 0)
      @session.instance_variable_set(:@write_queue, @queue)
    end

    def credit(bytes)
      @session.send(:credit_connection_window, bytes)
    end

    def returned
      @queue.sum { |cmd| cmd[0] == :send_window_update ? cmd[2] : 0 }
    end

    def outstanding
      @session.instance_variable_get(:@connection_unacked)
    end

    it 'sends nothing below the threshold' do
      credit(1024)
      expect(@queue).to be_empty
    end

    it 'ignores a zero length frame' do
      credit(0)
      expect(@queue).to be_empty
    end

    it 'accounts for every byte it is given' do
      total = 0
      256.times do
        credit(4096)
        total += 4096
      end
      expect(returned + outstanding).to eq(total)
    end

    it 'never leaves more than one threshold unreturned' do
      256.times { credit(4096) }
      expect(outstanding).to be < Session::WINDOW_UPDATE_THRESHOLD
    end

    it 'owes a discarded frame nothing at stream level' do
      credit(Session::WINDOW_UPDATE_THRESHOLD)
      update = @queue.find { |cmd| cmd[0] == :send_window_update }
      expect(update).not_to be_nil
      expect(update[3]).to eq(0)
    end
  end

  describe 'DATA that is thrown away' do
    def frame(type, flags, sid, payload = ''.b)
      [(payload.bytesize << 8) | type, flags, sid].pack('NCN') + payload
    end

    # Sums connection level WINDOW_UPDATE increments already on the wire.
    def drain_window_updates(sock, into)
      loop do
        header = sock.read_nonblock(9, exception: false)
        return if header == :wait_readable || header.nil? || header.bytesize < 9
        len_type, _flags, sid = header.unpack('NCN')
        len = len_type >> 8
        type = len_type & 0xFF
        body = len.positive? ? sock.read(len) : ''.b
        into[sid & 0x7FFF_FFFF] += body.unpack1('N') if type == 0x8
      end
    rescue IO::WaitReadable, IOError
      nil
    end

    it 'returns the connection window for a stream reset locally' do
      server_sock, peer = Socket.pair(:UNIX, :STREAM)
      [server_sock, peer].each do |sock|
        sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, 1 << 22)
        sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 1 << 22)
      end

      session = Session.new(server_sock, handler: SilentHandler.new)
      peer.write H2_PREFACE
      peer.write frame(0x4, 0, 0)
      session.receive

      headers = Kantan::H2::HPACK.new.encode(
        [[':method', 'POST'], [':scheme', 'http'],
         [':path', '/x'], [':authority', 'h']])
      peer.write frame(0x1, 0x04, 1, headers)
      sleep 0.1

      # From here the session discards everything sent on stream 1.
      session.send_rst_stream(1, 0x8)
      sleep 0.1

      # Enough to cross the threshold several times over. Sending less than
      # one threshold would make the assertion below true whatever the session
      # did with the bytes.
      updates = Hash.new(0)
      sent = 0
      payload = ('d' * DATA_CHUNK).b
      frames = (3 * Session::WINDOW_UPDATE_THRESHOLD) / DATA_CHUNK
      frames.times do
        peer.write frame(0x0, 0, 1, payload)
        sent += DATA_CHUNK
        drain_window_updates(peer, updates)
      end
      sleep 0.5
      drain_window_updates(peer, updates)

      expect(sent).to be > 2 * Session::WINDOW_UPDATE_THRESHOLD
      expect(updates[0]).to be >= sent - Session::WINDOW_UPDATE_THRESHOLD
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
