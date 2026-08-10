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
    # Picks which of a Channel's resolved-address Subchannels drives a call,
    # given grpc.lb_policy_name. Replaces the part of C-core's
    # grpc_lb_policy that Ruby used to reach only through channel arguments
    # C-core itself implemented.
    #
    # @api private
    module LbPolicyState
      module_function

      # Channel connectivity, generalised from one connection to several:
      # READY beats CONNECTING beats TRANSIENT_FAILURE, and the last of
      # those only holds when *every* address has given up. A mix of
      # TRANSIENT_FAILURE and untried IDLE addresses is IDLE, matching
      # "an IDLE channel connects immediately" once a caller asks it to.
      def aggregate(subchannels)
        states = subchannels.map(&:state)
        return ConnectivityStates::READY if states.include?(ConnectivityStates::READY)
        return ConnectivityStates::CONNECTING if states.include?(ConnectivityStates::CONNECTING)
        if states.all? { |s| s == ConnectivityStates::TRANSIENT_FAILURE }
          return ConnectivityStates::TRANSIENT_FAILURE
        end
        ConnectivityStates::IDLE
      end
    end

    # gRPC's default: dial addresses in the order the resolver returned
    # them, stick with the first one that connects, and only move to the
    # next once the one in use has failed.
    #
    # @api private
    class PickFirstPolicy
      def initialize(subchannels)
        @subchannels = subchannels
        @mu = Mutex.new
        @index = 0
      end

      def maybe_connect
        current.maybe_connect
      end

      def connectivity_state
        LbPolicyState.aggregate(@subchannels)
      end

      def last_error
        current.last_error
      end

      # The live subchannel for the next call, or nil while none is ready.
      def pick
        sc = current
        sc.alive? ? sc : nil
      end

      private

      # The address this policy is trying or bound to right now, skipping
      # forward over ones that have already failed so a dead first address
      # does not block a live second one behind it.
      def current
        @mu.synchronize do
          @index = (@index + 1) % @subchannels.size while advance_past_failure?
          @subchannels[@index]
        end
      end

      def advance_past_failure?
        sc = @subchannels[@index]
        return false if sc.state != ConnectivityStates::TRANSIENT_FAILURE
        @subchannels.any? { |other| !other.equal?(sc) && other.state != ConnectivityStates::TRANSIENT_FAILURE }
      end
    end

    # Holds one subchannel per resolved address and spreads calls across
    # whichever are currently ready, rather than concentrating every call on
    # a single one.
    #
    # @api private
    class RoundRobinPolicy
      def initialize(subchannels)
        @subchannels = subchannels
        @mu = Mutex.new
        @cursor = 0
      end

      def maybe_connect
        @subchannels.each(&:maybe_connect)
      end

      def connectivity_state
        LbPolicyState.aggregate(@subchannels)
      end

      def last_error
        @subchannels.map(&:last_error).compact.first
      end

      # Rotates across the ready subchannels so calls spread across every
      # live address instead of hammering whichever connected first.
      def pick
        ready = @subchannels.select(&:alive?)
        return nil if ready.empty?
        @mu.synchronize do
          sc = ready[@cursor % ready.size]
          @cursor += 1
          sc
        end
      end
    end

    # Every grpc.lb_policy_name this implementation understands.
    LB_POLICIES = {
      'pick_first' => PickFirstPolicy,
      'round_robin' => RoundRobinPolicy
    }.freeze
  end
end
