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

module GRPC
  module Core
    # Process-wide registry of live channels, backing the channelz debug
    # service (see Grpc::Channelz::V1::Channelz::Service). A channel
    # registers itself once, in its own constructor, and unregisters once,
    # from #destroy/#close -- never per call, so the hot RPC path never
    # touches this.
    #
    # Registration alone must never keep a channel alive: a channel a
    # caller drops without closing has to disappear from channelz once it
    # is garbage collected, exactly as a real process's channel table
    # would forget it. The registry is keyed by the channel's id (a plain
    # Integer, always strongly held, so it never itself keeps a channel
    # reachable) and holds the channel only in the WeakMap's value slot,
    # which the runtime drops once nothing else references it.
    module Channelz
      MUTEX = Mutex.new
      # channel_id (Integer) => Channel, weakly. A WeakMap key stays alive
      # only as long as something else references it; the Integer keys
      # here always do (Ruby Integers aren't garbage collected), so the
      # weakness that matters is entirely on the value side.
      #
      # Unregistering removes the key where ObjectSpace::WeakMap#delete
      # exists (Ruby 3.3+). On 3.2 it assigns nil: the id reads back as
      # gone at once, but an Integer => nil entry holds only immediates,
      # which GC never collects, so each closed channel leaves one small
      # entry behind there.
      CHANNELS = ObjectSpace::WeakMap.new
      DELETABLE = CHANNELS.respond_to?(:delete)
      private_constant :MUTEX, :CHANNELS, :DELETABLE
      @next_id = 1

      # Registers +channel+ and returns its new, unique, positive id.
      def self.register_channel(channel)
        MUTEX.synchronize do
          id = @next_id
          @next_id += 1
          CHANNELS[id] = channel
          id
        end
      end

      # Drops +channel_id+ from the registry. Safe to call more than once.
      def self.unregister_channel(channel_id)
        MUTEX.synchronize do
          if DELETABLE
            CHANNELS.delete(channel_id)
          else
            CHANNELS[channel_id] = nil
          end
        end
        nil
      end

      # Channels whose id is >= +start_id+, sorted by id ascending, as
      # [id, channel] pairs. A channel garbage collected without #close,
      # or already unregistered, has a nil value and is excluded.
      def self.channels_from(start_id)
        MUTEX.synchronize do
          CHANNELS.keys.select { |id| id >= start_id && !CHANNELS[id].nil? }
                       .sort.map { |id| [id, CHANNELS[id]] }
        end
      end

      # The live channel registered under +channel_id+, or nil.
      def self.channel(channel_id)
        MUTEX.synchronize { CHANNELS[channel_id] }
      end
    end
  end
end
