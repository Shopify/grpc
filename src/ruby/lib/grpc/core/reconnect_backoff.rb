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
    # gRPC's exponential reconnect backoff (see doc/connection-backoff.md):
    # start at the initial delay, multiply by 1.6 after every consecutive
    # failure, clamp to the max delay, and jitter each returned value by
    # +/-20 per cent so that many clients hammering the same down target do
    # not retry in lockstep. A successful connection resets the sequence.
    #
    # Used by Channel for the single re-resolve delay it schedules once
    # every resolved address has failed (see
    # Channel#schedule_reresolve_locked) -- there is only one backoff
    # sequence in this core, not a second one per subchannel.
    #
    # @api private
    class ReconnectBackoff
      MULTIPLIER = 1.6
      JITTER = 0.2

      def initialize(initial:, min:, max:)
        @min = min
        @max = max
        # Clamped the same way growth is, so a caller-supplied initial value
        # outside [min, max] cannot produce a first delay that violates the
        # bounds the same three arguments promise for every later one.
        @initial = [[initial, min].max, max].min
        @current = @initial
      end

      # The delay, in seconds, to wait before the next attempt. Advances the
      # unjittered sequence for the attempt after that.
      def next_delay
        delay = jittered(@current)
        @current = [[@current * MULTIPLIER, @min].max, @max].min
        delay
      end

      # Called after a connection succeeds, so the next failure backs off
      # from the initial delay again rather than continuing to grow.
      def reset
        @current = @initial
      end

      private

      # +/-20 per cent, uniformly distributed, exactly as grpc/core's
      # backoff.cc jitters each computed delay.
      def jittered(value)
        value + (value * JITTER * ((2 * rand) - 1))
      end
    end
  end
end
