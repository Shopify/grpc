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

FramingBody = GRPC::Core::Http2::Kantan::H2::Body

# Captures what reaches the session, so the framing can be checked without a
# socket underneath it.
class FramingCapturingSession
  attr_reader :sent

  def initialize
    @sent = []
  end

  def send_data(_id, data, end_stream: false, ack_to: nil, ack_size: 0)
    _ = end_stream
    @sent << data
    ack_to&.ack_write(ack_size)
  end
end

# A message that marshals to the String it holds.
class FramingStr
  attr_reader :bytes

  def initialize(bytes)
    @bytes = bytes
  end

  def self.marshal(obj)
    obj.bytes
  end

  def self.unmarshal(bytes)
    new(bytes)
  end
end

# Echoes its request straight back.
class FramingEchoService
  include GRPC::GenericService
  self.marshal_class_method = :marshal
  self.unmarshal_class_method = :unmarshal
  self.service_name = 'framing.Echo'
  rpc :Call, FramingStr, FramingStr

  def call(req, _call)
    FramingStr.new(req.bytes)
  end
end

# A message is framed as a five byte prefix followed by the payload, copied
# into one binary String. Two things have to hold on that path: the bytes come
# out exactly as they went in whatever encoding the caller used, and the frame
# does not alias the caller's String, because send_message returns while the
# frame is still queued.
describe FramingBody do
  let(:utf8) { 'héllo wörld ☃ 日本語' }
  # Starts with a three byte codepoint, so byte 1 falls inside it.
  let(:snowmen) { '☃☃☃ snow' }

  def buffer
    String.new(encoding: Encoding::BINARY, capacity: 256)
  end

  describe '.append_bytes' do
    it 'appends multibyte text as raw bytes' do
      buf = buffer
      described_class.append_bytes(buf, utf8)
      expect(buf.encoding).to eq(Encoding::BINARY)
      expect(buf).to eq(utf8.b)
      expect(buf.bytesize).to eq(utf8.bytesize)
    end

    it 'appends a binary string unchanged' do
      buf = buffer
      bytes = "\x00\xFF\x01\xFE".b
      described_class.append_bytes(buf, bytes)
      expect(buf).to eq(bytes)
    end

    it 'agrees with the String#b fallback' do
      # The fast path is String#append_as_bytes on Ruby 3.4 and later.
      # Whatever it does has to match what the older path produced.
      fast = buffer
      described_class.append_bytes(fast, utf8)
      slow = buffer
      slow << utf8.b
      expect(fast).to eq(slow)
    end

    it 'leaves the source alone' do
      before = utf8.dup
      described_class.append_bytes(buffer, utf8)
      expect(utf8).to eq(before)
      expect(utf8.encoding).to eq(Encoding::UTF_8)
    end
  end

  describe 'Buffer#read_into' do
    it 'writes a multibyte payload exactly, and says how much' do
      part = FramingBody::Buffer.new(utf8)
      buf = buffer
      written = part.read_into(buf, utf8.bytesize)
      expect(written).to eq(utf8.bytesize)
      expect(buf).to eq(utf8.b)
      expect(part).to be_empty
    end

    # The partial read is the path that used to break the write buffer. The
    # split lands inside the leading codepoint on purpose: a frame boundary
    # does not respect character boundaries, so the slice is not valid text.
    it 'writes a partial multibyte read exactly and resumes from there' do
      part = FramingBody::Buffer.new(snowmen)
      buf = buffer
      expect(part.read_into(buf, 1)).to eq(1)
      expect(buf.encoding).to eq(Encoding::BINARY)
      expect(part).not_to be_empty
      part.read_into(buf, snowmen.bytesize - 1)
      expect(buf).to eq(snowmen.b)
    end

    # The real setting: the buffer already holds a frame header whose length
    # field has a high byte, which is what makes a plain String#<< of a UTF-8
    # slice raise Encoding::CompatibilityError.
    it 'appends a split codepoint after a frame header with a high byte' do
      buf = buffer
      buf << 0x00 << 0xEA << 0x60 << 0x00 << 0x00
      part = FramingBody::Buffer.new(snowmen)
      expect { part.read_into(buf, 1) }.not_to raise_error
      part.read_into(buf, snowmen.bytesize - 1)
      expect(buf.encoding).to eq(Encoding::BINARY)
      expect(buf.byteslice(5..)).to eq(snowmen.b)
    end

    it 'never writes more than is left' do
      part = FramingBody::Buffer.new('abc')
      buf = buffer
      expect(part.read_into(buf, 100)).to eq(3)
      expect(buf).to eq('abc')
    end
  end
end

# The framing itself: RpcStream hands the transport one binary frame, and the
# five byte prefix has to be right for any payload encoding.
describe GRPC::Core::RpcStream do
  let(:session) { FramingCapturingSession.new }
  let(:connection) { double('connection', session: session) }
  let(:stream) do
    described_class.new(connection, 1, max_receive_message_length: -1)
  end

  def framed_bytes
    frame = session.sent.last
    expect(frame).to be_a(String)
    frame.b
  end

  describe '#send_message framing' do
    it 'sends the prefix and the payload as one binary frame' do
      stream.send_message('abc')
      expect(framed_bytes).to eq("\x00\x00\x00\x00\x03abc".b)
      expect(session.sent.last.encoding).to eq(Encoding::BINARY)
    end

    # The frame must not alias the caller's marshalled String: send_message
    # returns while the frame is still queued, and a marshaller is free to
    # reuse one buffer for every message.
    it 'copies the payload instead of holding the caller String' do
      payload = +'first payload'
      stream.send_message(payload)
      queued = session.sent.last
      payload.replace('something else entirely')
      expect(queued.byteslice(5..)).to eq('first payload')
    end

    it 'keeps the length prefix consistent with the bytes it queued' do
      payload = +('a' * 100)
      stream.send_message(payload)
      queued = session.sent.last
      payload.replace('short')
      expect(queued.byteslice(1, 4).unpack1('N')).to eq(100)
      expect(queued.bytesize).to eq(105)
    end

    it 'frames a multibyte payload by byte length, not character length' do
      payload = 'héllo ☃'
      stream.send_message(payload)
      bytes = framed_bytes
      expect(bytes.getbyte(0)).to eq(0)
      expect(bytes.byteslice(1, 4).unpack1('N')).to eq(payload.bytesize)
      expect(bytes.byteslice(5..)).to eq(payload.b)
      expect(payload.bytesize).not_to eq(payload.length)
    end

    it 'frames an empty payload' do
      stream.send_message('')
      expect(framed_bytes).to eq("\x00\x00\x00\x00\x00".b)
    end

    it 'frames a payload larger than one frame' do
      payload = ('x' * 70_000).b
      stream.send_message(payload)
      bytes = framed_bytes
      expect(bytes.byteslice(1, 4).unpack1('N')).to eq(70_000)
      expect(bytes.bytesize).to eq(70_005)
    end
  end
end

# The real shape of the bug the examples above guard against: a payload that
# is not binary and is larger than one HTTP/2 frame. A partial read of such a
# payload used to be appended with a plain String#<<, which raises
# Encoding::CompatibilityError against a write buffer that already holds a
# frame header with a high byte in it, taking the whole connection down.
describe 'a multibyte payload larger than one frame' do
  it 'round trips byte for byte' do
    server = GRPC::RpcServer.new(pool_size: 2, poll_period: 1)
    port = server.add_http2_port('127.0.0.1:0', :this_port_is_insecure)
    server.handle(FramingEchoService)
    thread = Thread.new { server.run }
    server.wait_till_running
    stub = FramingEchoService.rpc_stub_class.new("127.0.0.1:#{port}",
                                                 :this_channel_is_insecure)

    payload = '☃' * 20_000 # 60000 bytes, four 16 KiB frames
    expect(payload.bytesize).to be > 3 * 16_384
    expect(payload.bytesize).not_to eq(payload.length)

    got = stub.call(FramingStr.new(payload), deadline: Time.now + 30).bytes
    expect(got.b).to eq(payload.b)
  ensure
    server&.stop
    thread&.join(10)
  end
end
