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

# grpc.{initial,min,max}_reconnect_backoff_ms were accepted and never acted
# on: the re-resolve delay after every subchannel had failed was a hard-coded
# 0.05s, so a caller asking for a gentler retry schedule against a
# rate-limiting backend got none. grpc.per_message_compression was likewise
# accepted and ignored, so a caller that opted out of compression for cheap
# CPU-bound RPCs got charged for it anyway.
describe 'reconnect backoff' do
  include GRPC::Spec::Helpers

  after(:each) do
    @channel&.destroy
    @server&.stop
  end

  describe GRPC::Core::ReconnectBackoff do
    # Stubbing this instance's #rand to the jitter formula's midpoint
    # collapses +/-20 per cent of current_backoff * ((2 * rand) - 1) to
    # zero, so the growth sequence can be asserted exactly instead of
    # only within a band, without touching #rand anywhere else.
    def unjittered_backoff(initial:, min:, max:)
      backoff = described_class.new(initial: initial, min: min, max: max)
      allow(backoff).to receive(:rand).and_return(0.5)
      backoff
    end

    it 'starts at the configured initial value' do
      backoff = unjittered_backoff(initial: 1.0, min: 1.0, max: 120.0)
      expect(backoff.next_delay).to eq(1.0)
    end

    it 'multiplies by 1.6 on each consecutive failure' do
      backoff = unjittered_backoff(initial: 1.0, min: 1.0, max: 120.0)
      expect(backoff.next_delay).to eq(1.0)
      expect(backoff.next_delay).to eq(1.6)
      expect(backoff.next_delay).to eq(1.6 * 1.6)
    end

    it 'clamps growth at the configured maximum' do
      backoff = unjittered_backoff(initial: 1.0, min: 1.0, max: 5.0)
      10.times { backoff.next_delay }
      expect(backoff.next_delay).to eq(5.0)
    end

    it 'jitters every returned value by no more than 20 per cent' do
      backoff = described_class.new(initial: 1.0, min: 1.0, max: 120.0)
      current = 1.0
      20.times do
        delay = backoff.next_delay
        expect(delay).to be_within(0.2 * current).of(current)
        current = [current * 1.6, 120.0].min
      end
    end

    it 'resets to the initial value after a successful connection' do
      backoff = unjittered_backoff(initial: 1.0, min: 1.0, max: 120.0)
      backoff.next_delay
      backoff.next_delay
      backoff.reset
      expect(backoff.next_delay).to eq(1.0)
    end
  end

  describe 'the channel arguments' do
    it 'accepts the reconnect backoff arguments now that they work' do
      args = {
        'grpc.initial_reconnect_backoff_ms' => 500,
        'grpc.min_reconnect_backoff_ms' => 500,
        'grpc.max_reconnect_backoff_ms' => 5_000
      }
      expect { GRPC::Core::ChannelArgs.normalize(args) }.to_not raise_error
    end

    it 'builds a channel-level backoff from the configured milliseconds' do
      @channel = GRPC::Core::Channel.new(
        'localhost:0',
        { 'grpc.initial_reconnect_backoff_ms' => 250,
          'grpc.min_reconnect_backoff_ms' => 100,
          'grpc.max_reconnect_backoff_ms' => 2_000 },
        :this_channel_is_insecure)
      backoff = @channel.instance_variable_get(:@backoff)
      expect(backoff.instance_variable_get(:@initial)).to eq(0.25)
      expect(backoff.instance_variable_get(:@min)).to eq(0.1)
      expect(backoff.instance_variable_get(:@max)).to eq(2.0)
    end

    it "defaults to gRPC's own 1s/1s/120s when unset" do
      @channel = GRPC::Core::Channel.new('localhost:0', {}, :this_channel_is_insecure)
      backoff = @channel.instance_variable_get(:@backoff)
      expect(backoff.instance_variable_get(:@initial)).to eq(1.0)
      expect(backoff.instance_variable_get(:@min)).to eq(1.0)
      expect(backoff.instance_variable_get(:@max)).to eq(120.0)
    end

    it "resets the channel's backoff once a subchannel reports READY" do
      @channel = GRPC::Core::Channel.new(
        'localhost:0',
        { 'grpc.initial_reconnect_backoff_ms' => 100,
          'grpc.min_reconnect_backoff_ms' => 100,
          'grpc.max_reconnect_backoff_ms' => 10_000 },
        :this_channel_is_insecure)
      backoff = @channel.instance_variable_get(:@backoff)
      backoff.next_delay
      backoff.next_delay
      expect(backoff.instance_variable_get(:@current)).to be > 0.1
      @channel.send(:transition_locked, GRPC::Core::ConnectivityStates::READY)
      expect(backoff.instance_variable_get(:@current)).to eq(0.1)
    end
  end
end

# grpc.per_message_compression => 0 must land as no_compress on every
# message a client sends, exactly as WriteFlags::NO_COMPRESS does for one.
describe 'per-message compression' do
  include GRPC::Spec::Helpers

  after(:each) do
    @server&.stop
  end

  def build_stub(compression_enabled:)
    args = {
      'grpc.default_compression_algorithm' =>
        GRPC::Core::CompressionOptions::ALGORITHM_VALUES[:gzip]
    }
    args['grpc.per_message_compression'] = 0 unless compression_enabled
    build_insecure_stub(EchoStub, opts: { channel_args: args })
  end

  it 'sends an uncompressed message even though an algorithm was negotiated' do
    build_rpc_server
    run_services_on_server(@server, services: [EchoService]) do
      stub = build_stub(compression_enabled: false)
      expect(GRPC::Core::MessageCompression).to_not receive(:compress)
      expect(stub.an_rpc(EchoMsg.new(msg: 'ok')).msg).to eq('ok')
    end
  end

  it 'compresses with the negotiated algorithm by default' do
    build_rpc_server
    run_services_on_server(@server, services: [EchoService]) do
      stub = build_stub(compression_enabled: true)
      expect(GRPC::Core::MessageCompression).to receive(:compress)
        .with('gzip', anything).and_call_original
      expect(stub.an_rpc(EchoMsg.new(msg: 'ok')).msg).to eq('ok')
    end
  end

  describe 'the channel argument' do
    it 'accepts grpc.per_message_compression now that it works' do
      expect do
        GRPC::Core::ChannelArgs.normalize('grpc.per_message_compression' => 0)
      end.to_not raise_error
    end

    it 'defaults per_message_compression? to enabled' do
      channel = GRPC::Core::Channel.new('localhost:0', {}, :this_channel_is_insecure)
      expect(channel.per_message_compression?).to be(true)
      channel.destroy
    end

    it 'turns per_message_compression? off when set to 0' do
      channel = GRPC::Core::Channel.new(
        'localhost:0', { 'grpc.per_message_compression' => 0 }, :this_channel_is_insecure)
      expect(channel.per_message_compression?).to be(false)
      channel.destroy
    end
  end
end
