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

# Received DATA is appended into one buffer and read back out with a cursor,
# so a message is sliced once and the consumed prefix is reclaimed rather
# than resliced. gRPC message boundaries have nothing to do with HTTP/2 frame
# boundaries, so the cases worth pinning down are the awkward alignments: a
# message split across frames, a five byte length prefix split across frames,
# several messages inside one frame, and a message ending exactly on a frame
# boundary.
describe GRPC::Core::RpcStream, 'receive buffer' do
  let(:stream) do
    described_class.new(nil, 1, max_receive_message_length: -1)
  end

  def framed(body, compressed: 0)
    [compressed, body.bytesize].pack('CN') + body
  end

  def feed(*chunks)
    chunks.each { |c| stream.push_data(c.b) }
  end

  it 'reads a message that arrived in one frame' do
    feed framed('hello')
    expect(stream.read_message(nil)).to eq('hello')
  end

  it 'reads several messages out of one frame' do
    feed(framed('one') + framed('two') + framed('three'))
    expect(stream.read_message(nil)).to eq('one')
    expect(stream.read_message(nil)).to eq('two')
    expect(stream.read_message(nil)).to eq('three')
  end

  it 'reassembles a message split across frames' do
    body = 'abcdefghij' * 10
    bytes = framed(body)
    feed bytes.byteslice(0, 30), bytes.byteslice(30, 40), bytes.byteslice(70..)
    expect(stream.read_message(nil)).to eq(body)
  end

  it 'reads a prefix split across frames' do
    bytes = framed('payload')
    # One byte, then the rest of the prefix, then the body.
    feed bytes.byteslice(0, 1), bytes.byteslice(1, 4), bytes.byteslice(5..)
    expect(stream.read_message(nil)).to eq('payload')
  end

  it 'reads a prefix split one byte at a time' do
    bytes = framed('xyz')
    feed(*bytes.chars)
    expect(stream.read_message(nil)).to eq('xyz')
  end

  it 'handles a message that ends exactly on a frame boundary' do
    feed framed('aaaa'), framed('bbbb')
    expect(stream.read_message(nil)).to eq('aaaa')
    expect(stream.read_message(nil)).to eq('bbbb')
  end

  it 'handles a message that starts part way through a frame' do
    first = framed('aa')
    second = framed('bbbb')
    feed(first + second.byteslice(0, 3), second.byteslice(3..))
    expect(stream.read_message(nil)).to eq('aa')
    expect(stream.read_message(nil)).to eq('bbbb')
  end

  it 'reads an empty message' do
    feed framed('')
    expect(stream.read_message(nil)).to eq('')
  end

  it 'ignores an empty frame' do
    feed ''.b, framed('after')
    expect(stream.read_message(nil)).to eq('after')
  end

  it 'returns nil at a clean end of stream' do
    stream.push_eos
    expect(stream.read_message(nil)).to be_nil
  end

  it 'raises when the peer stops part way through a message' do
    bytes = framed('truncated here')
    feed bytes.byteslice(0, 8)
    stream.push_eos
    expect { stream.read_message(nil) }
      .to raise_error(GRPC::Core::RpcStream::Truncated)
  end

  it 'enforces the receive message limit' do
    limited = described_class.new(nil, 1, max_receive_message_length: 4)
    limited.push_data(framed('too long').b)
    expect { limited.read_message(nil) }
      .to raise_error(GRPC::Core::RpcStream::ResourceExhausted)
  end
end
