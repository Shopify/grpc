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

FrameReader = GRPC::Core::Http2::Kantan::H2::Session::FrameReader

describe FrameReader do
  def socket_pair
    reader, writer = Socket.pair(:UNIX, :STREAM)
    # These examples write and read on one thread, so every fixture has to fit
    # in the socket buffer or the write blocks for ever.
    [reader, writer].each do |sock|
      sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, 1 << 20)
      sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 1 << 20)
    end
    [FrameReader.new(reader), writer]
  end

  def frame(type: 0x0, flags: 0, sid: 1, payload: ''.b)
    [(payload.bytesize << 8) | type, flags, sid].pack('NCN') + payload
  end

  before(:each) do
    @reader, @writer = socket_pair
  end

  after(:each) do
    @writer.close
  rescue IOError
    nil
  end

  describe 'frame headers' do
    it 'decodes every field' do
      @writer.write frame(type: 0x1, flags: 0x5, sid: 9, payload: 'hello')
      expect(@reader.next_frame).to be true
      expect(@reader.length).to eq(5)
      expect(@reader.type).to eq(0x1)
      expect(@reader.flags).to eq(0x5)
      expect(@reader.stream_id).to eq(9)
      expect(@reader.read(5)).to eq('hello')
    end

    it 'clears the reserved bit of the stream id' do
      @writer.write [0x0, 0, 0x8000_0007].pack('NCN')
      expect(@reader.next_frame).to be true
      expect(@reader.stream_id).to eq(7)
    end

    it 'reassembles a frame split across many reads' do
      frame(payload: 'abcdefghij').each_char { |c| @writer.write(c) }
      expect(@reader.next_frame).to be true
      expect(@reader.length).to eq(10)
      expect(@reader.read(10)).to eq('abcdefghij')
    end

    it 'reads several frames out of one buffer refill' do
      @writer.write(3.times.map { |i| frame(payload: "p#{i}") }.join)
      3.times do |i|
        expect(@reader.next_frame).to be true
        expect(@reader.read(2)).to eq("p#{i}")
      end
    end
  end

  describe 'reading values in place' do
    it 'reads unsigned integers' do
      @writer.write [0xDEADBEEF].pack('N') + [0x0102030405060708].pack('Q>')
      expect(@reader.read_uint32).to eq(0xDEADBEEF)
      expect(@reader.read_uint64).to eq(0x0102030405060708)
    end

    it 'yields settings pairs' do
      @writer.write([[0x4, 65_535], [0x5, 16_384]].map { |i, v| [i, v].pack('nN') }.join)
      pairs = []
      @reader.each_setting(2) { |ident, value| pairs << [ident, value] }
      expect(pairs).to eq([[0x4, 65_535], [0x5, 16_384]])
    end

    it 'discards bytes with skip' do
      @writer.write("0123456789#{[0xCAFEBABE].pack('N')}")
      expect(@reader.skip(10)).to be true
      expect(@reader.read_uint32).to eq(0xCAFEBABE)
    end
  end

  describe 'end of stream' do
    it 'reports a clean end' do
      @writer.close
      expect(@reader.next_frame).to be false
    end

    it 'returns nil when the stream ends mid frame' do
      @writer.write 'ab'
      @writer.close
      expect(@reader.read(8)).to be_nil
    end

    # A refill that hits EOF must not leave the bytes it already handed out
    # visible to the next caller, or they get parsed a second time as a frame.
    it 'does not replay consumed bytes' do
      @writer.write frame(payload: 'abc')
      expect(@reader.next_frame).to be true
      expect(@reader.read(3)).to eq('abc')
      @writer.close
      expect(@reader.next_frame).to be false
      expect(@reader.next_frame).to be false
    end

    # The frame loop ignores the return of skip, so the reader itself has to
    # stay at end of stream afterwards.
    it 'stays at end of stream after a skip that could not complete' do
      @writer.write frame(payload: 'abcdef')
      expect(@reader.next_frame).to be true
      @writer.close
      expect(@reader.skip(100)).to be false
      expect(@reader.next_frame).to be false
    end
  end

  describe 'buffer reuse' do
    it 'keeps one buffer across refills' do
      ids = 5.times.map do
        @writer.write frame(payload: 'z' * 100)
        @reader.next_frame
        @reader.read(100)
        @reader.instance_variable_get(:@buf).object_id
      end
      expect(ids.uniq.size).to eq(1)
    end

    it 'decodes a header and skips a payload without allocating' do
      payload = 'y' * 100
      20.times { @writer.write frame(payload: payload) }
      5.times { @reader.next_frame && @reader.skip(100) }

      GC.disable
      before = GC.stat(:total_allocated_objects)
      10.times { @reader.next_frame && @reader.skip(100) }
      after = GC.stat(:total_allocated_objects)
      GC.enable

      expect((after - before) / 10.0).to be < 1.0
    end
  end
end
