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

require 'grpc'
require 'grpc/channelz/channelz_services_pb'
require 'grpc/core/channelz'

module Grpc
  module Channelz
    # Implements the subset of the channelz debug service (see
    # https://github.com/grpc/proposal/blob/master/A14-channelz.md) this
    # pure-Ruby port can back for free from GRPC::Core::Channelz: top
    # channels and single-channel lookup. Every other rpc the proto
    # declares (servers, sockets, subchannels) is left at the
    # UNIMPLEMENTED default #rpc's DSL already defines for every method
    # this class does not override -- this port has no server-side
    # channelz data (no Subchannel/Socket registry) to serve them from.
    class Service < V1::Channelz::Service
      StatusCodes = GRPC::Core::StatusCodes
      CoreStates = GRPC::Core::ConnectivityStates
      ProtoStates = V1::ChannelConnectivityState::State

      # Chosen to match core gRPC's channelz default page size.
      DEFAULT_MAX_RESULTS = 100

      # GRPC::Core::ConnectivityStates -> the channelz wire enum. A
      # destroyed channel's FATAL_FAILURE (there is no separate Ruby
      # constant for "shut down") is the only state that maps to anything
      # other than its same-named counterpart.
      STATE_MAP = {
        CoreStates::IDLE => ProtoStates::IDLE,
        CoreStates::CONNECTING => ProtoStates::CONNECTING,
        CoreStates::READY => ProtoStates::READY,
        CoreStates::TRANSIENT_FAILURE => ProtoStates::TRANSIENT_FAILURE,
        CoreStates::FATAL_FAILURE => ProtoStates::SHUTDOWN
      }.freeze
      private_constant :STATE_MAP

      def get_top_channels(req, _call)
        max_results = req.max_results.positive? ? req.max_results : DEFAULT_MAX_RESULTS
        entries = GRPC::Core::Channelz.channels_from(req.start_channel_id)
        page = entries.first(max_results)
        V1::GetTopChannelsResponse.new(
          channel: page.map { |id, channel| to_channel(id, channel) },
          end: page.size == entries.size
        )
      end

      def get_channel(req, _call)
        channel = GRPC::Core::Channelz.channel(req.channel_id)
        fail GRPC::BadStatus.new_status_exception(StatusCodes::NOT_FOUND) if channel.nil?
        V1::GetChannelResponse.new(channel: to_channel(req.channel_id, channel))
      end

      private

      def to_channel(id, channel)
        V1::Channel.new(
          ref: V1::ChannelRef.new(channel_id: id, name: channel.target),
          data: V1::ChannelData.new(
            state: V1::ChannelConnectivityState.new(
              state: STATE_MAP.fetch(channel.channelz_state, ProtoStates::UNKNOWN)
            ),
            target: channel.target
          )
        )
      end
    end
  end
end
