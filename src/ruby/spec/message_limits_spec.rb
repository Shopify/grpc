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

# grpc.max_send_message_length used to be accepted and never read, so an
# oversized message left the process and failed at the far end, or did not
# fail at all. A peer's compression algorithm was taken on trust in the same
# way, and an algorithm we cannot decompress raised ArgumentError out of the
# read path instead of the UNIMPLEMENTED the protocol asks for.
describe 'message limits and encodings' do
  include GRPC::Spec::Helpers

  describe 'grpc.max_send_message_length' do
    before(:each) do
      build_rpc_server
    end

    it 'fails a message over the limit with RESOURCE_EXHAUSTED' do
      run_services_on_server(@server, services: [EchoService]) do
        stub = build_insecure_stub(
          EchoStub,
          opts: { channel_args: { 'grpc.max_send_message_length' => 64 } })
        expect { stub.an_rpc(EchoMsg.new(msg: 'x' * 512)) }
          .to raise_error(GRPC::ResourceExhausted, /Sent message larger than max/)
      end
    end

    it 'reports both sizes so the caller can act on them' do
      run_services_on_server(@server, services: [EchoService]) do
        stub = build_insecure_stub(
          EchoStub,
          opts: { channel_args: { 'grpc.max_send_message_length' => 64 } })
        expect { stub.an_rpc(EchoMsg.new(msg: 'x' * 512)) }
          .to raise_error(GRPC::BadStatus, /\(5\d\d vs\. 64\)/)
      end
    end

    it 'passes a message under the limit' do
      run_services_on_server(@server, services: [EchoService]) do
        stub = build_insecure_stub(
          EchoStub,
          opts: { channel_args: { 'grpc.max_send_message_length' => 1024 } })
        expect(stub.an_rpc(EchoMsg.new(msg: 'small')).msg).to eq('small')
      end
    end

    it 'is unlimited when the argument is absent' do
      run_services_on_server(@server, services: [EchoService]) do
        stub = build_insecure_stub(EchoStub)
        expect(stub.an_rpc(EchoMsg.new(msg: 'x' * 200_000)).msg.bytesize)
          .to eq(200_000)
      end
    end
  end

  describe 'a message compressed with an algorithm we do not support' do
    let(:stream) do
      GRPC::Core::RpcStream.new(nil, 1, max_receive_message_length: 1 << 20)
    end

    # The gRPC length prefix: one compression flag byte, then four bytes of
    # length, big endian.
    def framed(body, compressed: 1)
      [compressed, body.bytesize].pack('CN') + body
    end

    it 'raises UnsupportedEncoding rather than a decoder error' do
      stream.push_headers([%w[grpc-encoding snappy]])
      stream.push_data(framed('nonsense'))
      expect { stream.read_message(nil) }
        .to raise_error(GRPC::Core::RpcStream::UnsupportedEncoding, /snappy/)
    end

    it 'names the encodings it does support' do
      stream.push_headers([%w[grpc-encoding br]])
      stream.push_data(framed('nonsense'))
      expect { stream.read_message(nil) }
        .to raise_error(GRPC::Core::RpcStream::UnsupportedEncoding,
                        /identity, deflate, gzip/)
    end

    it 'leaves an uncompressed message alone whatever the header says' do
      stream.push_headers([%w[grpc-encoding snappy]])
      stream.push_data(framed('plain', compressed: 0))
      expect(stream.read_message(nil)).to eq('plain')
    end

    it 'still reads a supported encoding' do
      stream.push_headers([%w[grpc-encoding gzip]])
      body = GRPC::Core::MessageCompression.compress('gzip', 'payload')
      stream.push_data(framed(body))
      expect(stream.read_message(nil)).to eq('payload')
    end
  end

  describe 'grpc.default_compression_algorithm' do
    let(:args) { GRPC::Core::ChannelArgs }

    it 'maps the enum value to the encoding the transport sends' do
      expect(args.compression_algorithm('grpc.default_compression_algorithm' => 2))
        .to eq('gzip')
    end

    it 'is nil for identity, which means no grpc-encoding header' do
      expect(args.compression_algorithm('grpc.default_compression_algorithm' => 0))
        .to be_nil
    end

    it 'declines an algorithm the enabled bitset excludes' do
      opts = {
        'grpc.default_compression_algorithm' => 2,
        'grpc.compression_enabled_algorithms_bitset' => 0x3
      }
      expect(args.compression_algorithm(opts)).to be_nil
    end

    it 'accepts what CompressionOptions produces' do
      hash = GRPC::Core::CompressionOptions
             .new(default_algorithm: :gzip).to_channel_arg_hash
      expect { args.normalize(hash) }.to_not raise_error
      expect(args.compression_algorithm(args.normalize(hash))).to eq('gzip')
    end
  end
end
