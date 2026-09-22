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
require 'grpc/channelz/service'

describe GRPC::Core::Channelz do
  let(:fake_host) { 'localhost:0' }

  it 'lists a live channel with its target and connectivity state' do
    ch = GRPC::Core::Channel.new(fake_host, nil, :this_channel_is_insecure)
    entries = described_class.channels_from(0)
    entry = entries.find { |_id, channel| channel.equal?(ch) }
    expect(entry).not_to be_nil
    id, channel = entry
    expect(id).to eq(ch.channelz_id)
    expect(channel.target).to eq(fake_host)
    expect(channel.channelz_state).to eq(GRPC::Core::ConnectivityStates::IDLE)
    ch.close
  end

  it 'drops a channel from the listing once it is closed' do
    ch = GRPC::Core::Channel.new(fake_host, nil, :this_channel_is_insecure)
    id = ch.channelz_id
    ch.close
    expect(described_class.channel(id)).to be_nil
    expect(described_class.channels_from(0).map(&:first)).not_to include(id)
  end

  it 'assigns unique, increasing ids to successive channels' do
    ch1 = GRPC::Core::Channel.new(fake_host, nil, :this_channel_is_insecure)
    ch2 = GRPC::Core::Channel.new(fake_host, nil, :this_channel_is_insecure)
    expect(ch2.channelz_id).to be > ch1.channelz_id
    ch1.close
    ch2.close
  end
end

describe Grpc::Channelz::Service do
  let(:service) { described_class.new }
  let(:fake_host) { 'localhost:0' }

  after(:each) { @channels&.each(&:close) }

  def new_channel
    ch = GRPC::Core::Channel.new(fake_host, nil, :this_channel_is_insecure)
    (@channels ||= []) << ch
    ch
  end

  describe '#get_top_channels' do
    it 'pages results honouring start_channel_id and max_results, and sets end' do
      channels = 3.times.map { new_channel }
      ids = channels.map(&:channelz_id).sort

      resp = service.get_top_channels(
        Grpc::Channelz::V1::GetTopChannelsRequest.new(start_channel_id: ids.first, max_results: 1), nil
      )
      expect(resp.channel.size).to eq(1)
      expect(resp.channel.first.ref.channel_id).to eq(ids.first)
      expect(resp.end).to eq(false)

      resp_all = service.get_top_channels(
        Grpc::Channelz::V1::GetTopChannelsRequest.new(start_channel_id: ids.first), nil
      )
      returned_ids = resp_all.channel.map { |c| c.ref.channel_id }
      expect(returned_ids).to eq(ids)
      expect(resp_all.end).to eq(true)

      resp_above = service.get_top_channels(
        Grpc::Channelz::V1::GetTopChannelsRequest.new(start_channel_id: ids.last + 1), nil
      )
      expect(resp_above.channel).to be_empty
      expect(resp_above.end).to eq(true)
    end

    it 'reports target and state on each listed channel' do
      ch = new_channel
      resp = service.get_top_channels(
        Grpc::Channelz::V1::GetTopChannelsRequest.new(start_channel_id: ch.channelz_id), nil
      )
      entry = resp.channel.find { |c| c.ref.channel_id == ch.channelz_id }
      expect(entry.data.target).to eq(fake_host)
      expect(entry.data.state.state).to eq(:IDLE)
    end
  end

  describe '#get_channel' do
    it 'returns the channel matching the requested id' do
      ch = new_channel
      resp = service.get_channel(Grpc::Channelz::V1::GetChannelRequest.new(channel_id: ch.channelz_id), nil)
      expect(resp.channel.ref.channel_id).to eq(ch.channelz_id)
      expect(resp.channel.data.target).to eq(fake_host)
    end

    it 'raises NOT_FOUND for an unknown id' do
      blk = proc { service.get_channel(Grpc::Channelz::V1::GetChannelRequest.new(channel_id: -1), nil) }
      expect(&blk).to raise_error(GRPC::BadStatus) { |e| expect(e.code).to eq(GRPC::Core::StatusCodes::NOT_FOUND) }
    end
  end

  describe 'every other rpc' do
    it 'is UNIMPLEMENTED' do
      blk = proc { service.get_servers(Grpc::Channelz::V1::GetServersRequest.new, nil) }
      expect(&blk).to raise_error(GRPC::BadStatus) { |e| expect(e.code).to eq(GRPC::Core::StatusCodes::UNIMPLEMENTED) }
    end
  end

  describe 'over a real RpcServer' do
    before(:each) do
      server_host = '0.0.0.0:0'
      @srv = new_rpc_server_for_testing(poll_period: 1)
      @srv.handle(Grpc::Channelz::Service.new)
      server_port = @srv.add_http2_port(server_host, :this_port_is_insecure)
      @host = "localhost:#{server_port}"
    end

    after(:each) do
      @srv.stop
    end

    it 'answers GetTopChannels for a channel dialed against the same server' do
      Thread.abort_on_exception = true
      t = Thread.new { @srv.run }
      @srv.wait_till_running

      stub_channel = GRPC::Core::Channel.new(@host, nil, :this_channel_is_insecure)
      stub = Grpc::Channelz::V1::Channelz::Stub.new(
        @host, :this_channel_is_insecure, channel_override: stub_channel
      )
      resp = stub.get_top_channels(Grpc::Channelz::V1::GetTopChannelsRequest.new(start_channel_id: 0))
      expect(resp.channel.map { |c| c.ref.channel_id }).to include(stub_channel.channelz_id)
      entry = resp.channel.find { |c| c.ref.channel_id == stub_channel.channelz_id }
      expect(entry.data.target).to eq(@host)

      stub_channel.close
      @srv.stop
      t.join
    end
  end
end
