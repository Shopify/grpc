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

# Configuration this implementation cannot act on has to say so. Accepting a
# keepalive setting and never sending a PING, or parsing
# "google-c2p:///service" as the host "google-c2p", leaves the caller to
# discover it from an outage instead of from an error.
describe 'configuration this implementation does not implement' do
  describe GRPC::Core::ChannelArgs do
    # grpc.census stands in for "a gRPC argument we do not implement". It is
    # used here rather than a transport setting because features land over
    # time and this example should not need editing each time one does.
    it 'rejects a gRPC argument it does not act on' do
      expect { described_class.normalize('grpc.census' => 1) }
        .to raise_error(ArgumentError, /grpc.census is not implemented/)
    end

    it 'names every rejected argument, not just the first' do
      args = { 'grpc.census' => 1, 'grpc.max_connections_per_subchannel_cap' => 4 }
      expect { described_class.normalize(args) }
        .to raise_error(ArgumentError, /grpc.census, grpc.max_connections_per_subchannel_cap/)
    end

    it 'tells the caller which arguments do work' do
      expect { described_class.normalize('grpc.census' => 1) }
        .to raise_error(ArgumentError, /grpc.max_receive_message_length/)
    end

    it 'accepts every argument it honours' do
      args = {
        'grpc.default_authority' => 'a.example',
        'grpc.max_concurrent_streams' => 10,
        'grpc.max_receive_message_length' => 1024,
        'grpc.max_send_message_length' => 1024,
        'grpc.primary_user_agent' => 'x',
        'grpc.so_reuseport' => 0,
        'grpc.ssl_target_name_override' => 'b.example'
      }
      expect { described_class.normalize(args) }.to_not raise_error
    end

    # The C extension passed unknown arguments to core, which ignored them,
    # and channel_spec.rb pins that. Only the "grpc." namespace is ours.
    it 'ignores an argument outside the grpc namespace' do
      expect(described_class.normalize('a_symbol' => 1)).to eq('a_symbol' => 1)
    end

    it 'rejects a misspelled gRPC argument rather than dropping it' do
      expect { described_class.normalize('grpc.max_recieve_message_length' => 1) }
        .to raise_error(ArgumentError)
    end
  end

  describe GRPC::Core::Transport do
    it 'rejects a scheme it cannot resolve' do
      expect { described_class.parse_target('some-bogus-scheme:///my-service') }
        .to raise_error(ArgumentError, /unsupported target scheme "some-bogus-scheme"/)
    end

    it 'rejects google-c2p, which it also cannot resolve' do
      expect { described_class.parse_target('google-c2p:///my-service') }
        .to raise_error(ArgumentError, /google-c2p/)
    end

    it 'still resolves the schemes it does support' do
      target = described_class.parse_target('dns:///host.example:50051')
      expect([target.host, target.port]).to eq(['host.example', 50_051])
    end

    # "localhost:50051" is a host and a port, not a scheme and a path.
    it 'does not mistake a host and port for a scheme' do
      target = described_class.parse_target('localhost:50051')
      expect([target.host, target.port]).to eq(['localhost', 50_051])
    end

    it 'still resolves a unix socket path' do
      expect(described_class.parse_target('unix:/tmp/s.sock').path)
        .to eq('/tmp/s.sock')
    end
  end

  describe GRPC::Core::Channel do
    it 'fails to build rather than ignore an unimplemented argument' do
      expect do
        described_class.new('localhost:1', { 'grpc.census' => 1 },
                            :this_channel_is_insecure)
      end.to raise_error(ArgumentError)
    end

    it 'fails to build on a scheme it cannot resolve' do
      expect do
        described_class.new('google-c2p:///svc', nil, :this_channel_is_insecure)
      end.to raise_error(ArgumentError)
    end
  end
end
