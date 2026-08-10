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

# A DATA payload is appended straight from the frame reader's buffer into the
# stream's receive buffer, so nothing cuts a String out for it. These cover
# the pieces that path is built from, and the boundaries where a message and
# a frame line up badly.
describe 'the inbound DATA path' do
  let(:body_mod) { GRPC::Core::Http2::Kantan::H2::Body }

  describe 'Body.append_slice' do
    let(:buf) { String.new(encoding: Encoding::BINARY) << 0xff }

    it 'appends the requested byte range' do
      body_mod.append_slice(buf, 'abcdefgh'.b, 2, 3)
      expect(buf.bytes).to eq([0xff, *'cde'.bytes])
    end

    it 'appends nothing for a zero length' do
      body_mod.append_slice(buf, 'abc'.b, 1, 0)
      expect(buf.bytes).to eq([0xff])
    end

    it 'reaches the last byte of the source' do
      body_mod.append_slice(buf, 'abc'.b, 2, 1)
      expect(buf.bytes).to eq([0xff, *'c'.bytes])
    end

    # The buffer already holds a frame header with a high byte in it, so a
    # plain << of a UTF-8 slice would raise Encoding::CompatibilityError.
    it 'takes bytes from a UTF-8 source without disturbing the buffer' do
      text = 'héllo'
      body_mod.append_slice(buf, text, 0, text.bytesize)
      expect(buf.encoding).to eq(Encoding::BINARY)
      expect(buf.bytes).to eq([0xff, *text.b.bytes])
    end

    it 'takes a range that splits a codepoint' do
      body_mod.append_slice(buf, 'héllo', 0, 2)
      expect(buf.bytes).to eq([0xff, *'hé'.b.bytes[0, 2]])
    end
  end

  describe 'Kantan::Handler#on_data_into' do
    # A handler that only implements #on_data still receives its payload.
    let(:handler) do
      Class.new(GRPC::Core::Http2::Kantan::Handler) do
        attr_reader :seen

        def on_data(_stream, chunk)
          (@seen ||= []) << chunk
        end
      end.new
    end

    let(:reader) do
      Class.new do
        def initialize(bytes)
          @bytes = bytes
        end

        def read(len)
          @bytes.byteslice(0, len)
        end
      end
    end

    it 'falls back to #on_data for handlers that do not override it' do
      handler.on_data_into(:stream, reader.new('payload'.b), 7)
      expect(handler.seen).to eq(['payload'.b])
    end
  end

  describe 'a message whose size lines up badly with the frame size' do
    include GRPC::Spec::Helpers

    before(:each) do
      build_rpc_server
      @stub = EchoStub.new(@host, :this_channel_is_insecure)
    end

    def echo(msg)
      result = nil
      run_services_on_server(@server, services: [EchoService]) do
        result = @stub.an_rpc(EchoMsg.new(msg: msg)).msg
      end
      result
    end

    # 16384 is one DATA frame. The five byte gRPC prefix means a payload of
    # exactly that size spills one byte into a second frame, and 16379 fills
    # the first frame exactly.
    [0, 1, 16_378, 16_379, 16_380, 16_384, 32_768, 65_536].each do |size|
      it "round trips a #{size} byte payload" do
        msg = 'x' * size
        expect(echo(msg)).to eq(msg)
      end
    end

    it 'round trips a payload that is not valid UTF-8' do
      msg = (0..255).to_a.pack('C*') * 200
      expect(echo(msg).b).to eq(msg.b)
    end

    it 'round trips many messages in a row on one connection' do
      run_services_on_server(@server, services: [EchoService]) do
        10.times do |i|
          msg = 'y' * (16_380 + i)
          expect(@stub.an_rpc(EchoMsg.new(msg: msg)).msg).to eq(msg)
        end
      end
    end
  end
end
