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

# grpc.max_metadata_size was accepted and never enforced, so a peer that
# handed over an unbounded HEADERS block just got to spend whatever memory
# it liked. grpc.default_compression_level was outright refused. Both are
# genuine C-core behaviour this pure Ruby core was missing.
describe 'metadata limits and compression level' do
  include GRPC::Spec::Helpers

  describe GRPC::Core::Metadata do
    # 32 bytes of fixed overhead per pair, matching what grpc_metadata_batch
    # charges beyond the raw name/value bytes.
    it 'sums name and value bytes plus the fixed per-pair overhead' do
      pairs = [%w[k v], %w[ab cde]]
      expect(described_class.size(pairs)).to eq((1 + 1 + 32) + (2 + 3 + 32))
    end

    it 'passes metadata at or under the limit' do
      pairs = [%w[k v]]
      expect { described_class.check_size!(pairs, described_class.size(pairs)) }
        .to_not raise_error
    end

    it 'fails metadata over the limit' do
      pairs = [%w[k v]]
      expect { described_class.check_size!(pairs, described_class.size(pairs) - 1) }
        .to raise_error(GRPC::Core::Metadata::ResourceExhausted)
    end

    # A pair whose raw bytes comfortably fit the limit still has to fail once
    # the fixed overhead is counted, or the accounting is decorative.
    it 'applies the per-pair overhead even when the raw bytes are tiny' do
      pairs = [%w[k v]] # 2 raw bytes, 34 counted
      expect { described_class.check_size!(pairs, 33) }
        .to raise_error(GRPC::Core::Metadata::ResourceExhausted)
      expect { described_class.check_size!(pairs, 34) }.to_not raise_error
    end

    it 'treats a nil limit as unlimited' do
      expect { described_class.check_size!([['k', 'v' * 1_000_000]], nil) }
        .to_not raise_error
    end
  end

  describe GRPC::Core::ChannelArgs do
    it 'is now in HONOURED for grpc.max_metadata_size' do
      expect(described_class::HONOURED).to include('grpc.max_metadata_size')
    end

    it 'is now in HONOURED for grpc.default_compression_level' do
      expect(described_class::HONOURED).to include('grpc.default_compression_level')
    end

    it 'accepts grpc.max_metadata_size' do
      expect { described_class.normalize('grpc.max_metadata_size' => 1024) }
        .to_not raise_error
    end

    it 'accepts CompressionOptions.new(default_level: :high).to_channel_arg_hash' do
      args = GRPC::Core::CompressionOptions.new(default_level: :high).to_channel_arg_hash
      expect { described_class.normalize(args) }.to_not raise_error
    end

    describe '.compression_algorithm' do
      it 'picks gzip for a non-none level' do
        expect(described_class.compression_algorithm(
                 'grpc.default_compression_level' =>
                   GRPC::Core::CompressionOptions::LEVEL_VALUES[:high]
               )).to eq('gzip')
      end

      it 'picks identity (no algorithm) for level none' do
        expect(described_class.compression_algorithm(
                 'grpc.default_compression_level' =>
                   GRPC::Core::CompressionOptions::LEVEL_VALUES[:none]
               )).to be_nil
      end

      it 'lets an explicit algorithm win over a level' do
        args = {
          'grpc.default_compression_algorithm' =>
            GRPC::Core::CompressionOptions::ALGORITHM_VALUES[:deflate],
          'grpc.default_compression_level' =>
            GRPC::Core::CompressionOptions::LEVEL_VALUES[:high]
        }
        expect(described_class.compression_algorithm(args)).to eq('deflate')
      end

      it 'lets an explicit identity algorithm win over a level too' do
        args = {
          'grpc.default_compression_algorithm' =>
            GRPC::Core::CompressionOptions::ALGORITHM_VALUES[:identity],
          'grpc.default_compression_level' =>
            GRPC::Core::CompressionOptions::LEVEL_VALUES[:high]
        }
        expect(described_class.compression_algorithm(args)).to be_nil
      end

      it 'does not offer a level-selected algorithm the bitset disables' do
        gzip = GRPC::Core::CompressionOptions::ALGORITHM_VALUES[:gzip]
        args = {
          'grpc.default_compression_level' =>
            GRPC::Core::CompressionOptions::LEVEL_VALUES[:high],
          'grpc.compression_enabled_algorithms_bitset' => ~(1 << gzip)
        }
        expect(described_class.compression_algorithm(args)).to be_nil
      end
    end
  end

  describe 'enforced over a live connection' do
    it 'passes metadata under the limit' do
      build_rpc_server
      run_services_on_server(@server, services: [EchoService]) do
        stub = build_insecure_stub(EchoStub)
        expect(
          stub.an_rpc(EchoMsg.new(msg: 'ok'), metadata: { 'small' => 'value' }).msg
        ).to eq('ok')
      end
    end

    # The server must answer the client with RESOURCE_EXHAUSTED, not merely
    # drop the connection: the peer needs a status it can act on, and a
    # dropped connection would surface as UNAVAILABLE instead.
    it 'fails an oversized request with RESOURCE_EXHAUSTED, not a dropped connection' do
      build_rpc_server(server_opts: { server_args: { 'grpc.max_metadata_size' => 256 } })
      run_services_on_server(@server, services: [EchoService]) do
        stub = build_insecure_stub(EchoStub)
        expect do
          stub.an_rpc(EchoMsg.new(msg: 'ok'), metadata: { 'big' => 'x' * 10_000 })
        end.to raise_error(GRPC::ResourceExhausted, /grpc.max_metadata_size/)
      end
    end

    # Received metadata is enforced on both sides: a server whose response
    # (here, trailing metadata) is heavier than the client's own limit fails
    # the RPC for the client, without the server having done anything wrong
    # by its own limit.
    it 'fails when the received response metadata is oversized on the client' do
      build_rpc_server
      run_services_on_server(@server, services: [EchoService.new(big: 'x' * 10_000)]) do
        stub = build_insecure_stub(
          EchoStub,
          opts: { channel_args: { 'grpc.max_metadata_size' => 256 } })
        expect { stub.an_rpc(EchoMsg.new(msg: 'ok')) }
          .to raise_error(GRPC::ResourceExhausted, /grpc.max_metadata_size/)
      end
    end
  end
end
