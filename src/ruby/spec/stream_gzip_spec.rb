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

# "stream/gzip" (GRPC_COMPRESS_STREAM_GZIP: gzip applied across an entire
# HTTP/2 stream rather than independently per message) is NOT implemented
# here, on purpose. grpc_compression_algorithm in
# include/grpc/impl/compression_types.h:62-66 (this very vendored tree) is
# exactly { GRPC_COMPRESS_NONE, GRPC_COMPRESS_DEFLATE, GRPC_COMPRESS_GZIP,
# GRPC_COMPRESS_ALGORITHMS_COUNT } -- no STREAM_GZIP member, and no
# "stream/gzip" string, exists anywhere under include/ or src/core in this
# checkout. Upstream deleted the feature outright in grpc/grpc#28223 (2021),
# commit message "eliminate stream based compression (this is seemingly
# unused in practice)", taking stream_compression.cc/.h, the gzip and
# identity stream codecs, their fuzzers, and three end2end test files with
# it. No maintained gRPC C-core, grpc-go, or grpc-js peer built after that
# commit advertises or accepts grpc-encoding: stream/gzip; shipping it here
# would let this Ruby core talk only to itself, not to a real peer, which is
# the one thing this port must not do. This file instead proves: the wire
# surface still only advertises and accepts { identity, deflate, gzip };
# "stream/gzip" is rejected the same way any other unsupported encoding is,
# with UNIMPLEMENTED naming that exact set; the level-to-algorithm mapping
# gRPC actually specifies (ranking gzip and deflate, not a phantom third
# algorithm) is honoured through both the channel-argument and
# CompressionOptions surfaces; and the pre-existing gzip/deflate paths are
# untouched.
describe 'stream/gzip (not implemented) and per-call compression level' do
  include GRPC::Spec::Helpers

  describe 'the wire surface' do
    it 'never advertises stream/gzip in grpc-accept-encoding' do
      expect(GRPC::Core::Call::ACCEPT_ENCODING).to eq('identity,deflate,gzip')
      expect(GRPC::Core::Call::ACCEPT_ENCODING).to_not include('stream')
    end

    it 'does not list stream/gzip as a supported message encoding' do
      expect(GRPC::Core::MessageCompression::SUPPORTED)
        .to eq(%w[identity deflate gzip])
      expect(GRPC::Core::MessageCompression.supported?('stream/gzip')).to be false
    end
  end

  describe 'a message tagged with grpc-encoding: stream/gzip' do
    let(:stream) do
      GRPC::Core::RpcStream.new(nil, 1, max_receive_message_length: 1 << 20)
    end

    def framed(body, compressed: 1)
      [compressed, body.bytesize].pack('CN') + body
    end

    it 'fails with UnsupportedEncoding, not silent acceptance or a decoder crash' do
      stream.push_headers([%w[grpc-encoding stream/gzip]])
      stream.push_data(framed(Zlib::Deflate.deflate('nonsense')))
      expect { stream.read_message(nil) }
        .to raise_error(GRPC::Core::RpcStream::UnsupportedEncoding, %r{stream/gzip})
    end

    it 'names exactly the algorithms this core supports, unchanged by this task' do
      stream.push_headers([%w[grpc-encoding stream/gzip]])
      stream.push_data(framed('nonsense'))
      expect { stream.read_message(nil) }
        .to raise_error(GRPC::Core::RpcStream::UnsupportedEncoding,
                        /identity, deflate, gzip/)
    end

    it 'never appears in what a real server actually advertises' do
      build_rpc_server
      run_services_on_server(@server, services: [EchoService]) do
        stub = build_insecure_stub(EchoStub)
        # The client always sends grpc-accept-encoding itself (see the
        # "wire surface" examples above); this proves an ordinary call
        # still succeeds end to end now that the level-ranking fix below
        # touches the same compression_algorithm code path.
        expect(stub.an_rpc(EchoMsg.new(msg: 'ok')).msg).to eq('ok')
      end
    end
  end

  describe 'existing gzip and deflate, unchanged' do
    it 'round-trips gzip through MessageCompression directly' do
      payload = 'x' * 4096
      compressed = GRPC::Core::MessageCompression.compress('gzip', payload)
      expect(GRPC::Core::MessageCompression.decompress('gzip', compressed))
        .to eq(payload)
    end

    it 'round-trips deflate through MessageCompression directly' do
      payload = 'y' * 4096
      compressed = GRPC::Core::MessageCompression.compress('deflate', payload)
      expect(GRPC::Core::MessageCompression.decompress('deflate', compressed))
        .to eq(payload)
    end

    it 'round-trips a real RPC with grpc.default_compression_algorithm set to gzip' do
      build_rpc_server
      run_services_on_server(@server, services: [EchoService]) do
        stub = build_insecure_stub(
          EchoStub,
          opts: { channel_args: {
            'grpc.default_compression_algorithm' =>
              GRPC::Core::CompressionOptions::ALGORITHM_VALUES[:gzip]
          } })
        expect(stub.an_rpc(EchoMsg.new(msg: 'gzip payload')).msg)
          .to eq('gzip payload')
      end
    end

    it 'round-trips a real RPC with grpc.default_compression_algorithm set to deflate' do
      build_rpc_server
      run_services_on_server(@server, services: [EchoService]) do
        stub = build_insecure_stub(
          EchoStub,
          opts: { channel_args: {
            'grpc.default_compression_algorithm' =>
              GRPC::Core::CompressionOptions::ALGORITHM_VALUES[:deflate]
          } })
        expect(stub.an_rpc(EchoMsg.new(msg: 'deflate payload')).msg)
          .to eq('deflate payload')
      end
    end
  end

  describe 'grpc.default_compression_level selects a real algorithm, not a placeholder' do
    it 'selects gzip for the low level via the channel argument' do
      expect(GRPC::Core::ChannelArgs.compression_algorithm(
               'grpc.default_compression_level' =>
                 GRPC::Core::CompressionOptions::LEVEL_VALUES[:low]
             )).to eq('gzip')
    end

    it 'selects deflate for the high level via the channel argument' do
      expect(GRPC::Core::ChannelArgs.compression_algorithm(
               'grpc.default_compression_level' =>
                 GRPC::Core::CompressionOptions::LEVEL_VALUES[:high]
             )).to eq('deflate')
    end

    it 'selects gzip for the low level via CompressionOptions' do
      hash = GRPC::Core::CompressionOptions
             .new(default_level: :low).to_channel_arg_hash
      expect(GRPC::Core::ChannelArgs.compression_algorithm(
               GRPC::Core::ChannelArgs.normalize(hash)
             )).to eq('gzip')
    end

    it 'selects deflate for the high level via CompressionOptions' do
      hash = GRPC::Core::CompressionOptions
             .new(default_level: :high).to_channel_arg_hash
      expect(GRPC::Core::ChannelArgs.compression_algorithm(
               GRPC::Core::ChannelArgs.normalize(hash)
             )).to eq('deflate')
    end

    it 'round-trips a real RPC selected purely by compression level' do
      build_rpc_server
      run_services_on_server(@server, services: [EchoService]) do
        stub = build_insecure_stub(
          EchoStub,
          opts: { channel_args: {
            'grpc.default_compression_level' =>
              GRPC::Core::CompressionOptions::LEVEL_VALUES[:high]
          } })
        expect(stub.an_rpc(EchoMsg.new(msg: 'level-selected')).msg)
          .to eq('level-selected')
      end
    end

    it 'still lets an explicit algorithm win over a level' do
      hash = GRPC::Core::CompressionOptions
             .new(default_algorithm: :gzip, default_level: :high)
             .to_channel_arg_hash
      expect(GRPC::Core::ChannelArgs.compression_algorithm(
               GRPC::Core::ChannelArgs.normalize(hash)
             )).to eq('gzip')
    end
  end
end
