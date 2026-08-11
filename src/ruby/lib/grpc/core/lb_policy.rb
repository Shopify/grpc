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

require 'zlib'

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
      #
      # A subchannel whose transport is READY but whose client-side health
      # check (see HealthWatcher) has not reported SERVING does not count
      # as READY here: gRFC A17 makes that subchannel unusable, and an
      # aggregate that called the channel READY anyway would let a caller
      # believe a call could go out when #pick has nothing to hand it.
      def aggregate(subchannels)
        if subchannels.any? { |sc| sc.state == ConnectivityStates::READY && sc.healthy? }
          return ConnectivityStates::READY
        end
        states = subchannels.map(&:state)
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
      def initialize(subchannels, _args = nil)
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
      # +_hash_key+ is accepted and ignored: pick_first has nothing to hash
      # onto, only ring_hash reads it.
      def pick(_hash_key = nil)
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
      def initialize(subchannels, _args = nil)
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
      # +_hash_key+ is accepted and ignored, matching #pick everywhere else.
      def pick(_hash_key = nil)
        ready = @subchannels.select(&:alive?)
        return nil if ready.empty?
        @mu.synchronize do
          sc = ready[@cursor % ready.size]
          @cursor += 1
          sc
        end
      end
    end

    # gRFC A42: instead of every call landing on whichever address
    # round_robin next rotates to, this hashes the call onto a point on a
    # ring built from the resolved addresses and walks the ring clockwise to
    # the first address whose subchannel is usable. The same key lands on
    # the same address for as long as that address stays on the ring, and
    # removing an address only moves the keys that were already going to it
    # -- the property that makes ring_hash worth its extra bookkeeping over
    # round_robin, which would reshuffle every key on any membership change.
    #
    # @api private
    class RingHashPolicy
      # grpc.lb.ring_hash.ring_size_cap's default, and the default minimum
      # and maximum ring sizes a config that does not name its own would
      # use, matching src/core/load_balancing/ring_hash/ring_hash.cc.
      DEFAULT_RING_SIZE_CAP = 4096
      DEFAULT_MIN_RING_SIZE = 1024
      DEFAULT_MAX_RING_SIZE = 4096

      def initialize(subchannels, args = nil)
        @subchannels = subchannels
        build_ring(args || {})
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

      # +hash_key+ is a call's x-grpc-hash-key metadata value, or nil when
      # the call carried none. Hashing it always lands on the same ring
      # position -- and so, absent a membership change, the same address --
      # for every call that carries the same key. With no key there is
      # nothing to be consistent about, so each call gets an independent
      # random position (mirroring C-core's use_random_hash fallback)
      # rather than pinning every keyless call to whichever address the
      # ring happens to start on.
      #
      # Walking forward from that position touches nothing but Integer
      # arithmetic and Array#[] on the fixed-size arrays #build_ring
      # already produced: a pick itself allocates nothing.
      def pick(hash_key = nil)
        size = @ring_hashes.size
        return nil if size.zero?
        start = ring_position(request_hash(hash_key))
        i = 0
        while i < size
          sc = @subchannels[@ring_endpoints[(start + i) % size]]
          return sc if sc.alive?
          i += 1
        end
        nil
      end

      private

      # CRC32 -- already linked in via message_compression.rb's 'zlib', so
      # this adds no new dependency -- rather than a cryptographic or 64 bit
      # hash: consistent hashing only needs a cheap, evenly distributed
      # function, and 32 bits comfortably covers ring sizes up to the
      # 8388608 ceiling gRPC itself imposes on min/max ring size.
      def request_hash(hash_key)
        return Zlib.crc32(hash_key) if hash_key.is_a?(String) && !hash_key.empty?
        Random.rand(0x1_0000_0000)
      end

      # Ported from ring_hash.cc's ketama_get_server binary search: the
      # index of the first ring entry at or after +hash+, wrapping to the
      # start when +hash+ is past every entry.
      def ring_position(hash)
        lo = 0
        hi = @ring_hashes.size - 1
        while lo < hi
          mid = (lo + hi) / 2
          if @ring_hashes[mid] < hash
            lo = mid + 1
          else
            hi = mid
          end
        end
        @ring_hashes[lo] < hash ? 0 : lo
      end

      # A per-resolution cost, not a per-RPC one: ported from ring_hash.cc's
      # Ring constructor. Each address gets floor/ceil(scale * its
      # normalized weight) points on the ring, scaled so the least-weighted
      # address still gets a whole number of them, and the total is fit
      # between the default min/max ring size and capped by
      # grpc.lb.ring_hash.ring_size_cap.
      def build_ring(args)
        weights = @subchannels.map { |sc| endpoint_weight(sc) }
        sum = weights.sum.to_f
        normalized = weights.map { |w| w / sum }
        cap = ChannelArgs.int(args, ChannelArgs::RING_HASH_LB_RING_SIZE_CAP, DEFAULT_RING_SIZE_CAP)
        min_ring_size = [DEFAULT_MIN_RING_SIZE, cap].min
        max_ring_size = [DEFAULT_MAX_RING_SIZE, cap].min
        min_normalized = normalized.min
        scale = [(min_normalized * min_ring_size).ceil / min_normalized, max_ring_size.to_f].min
        entries = []
        current_hashes = 0.0
        target_hashes = 0.0
        @subchannels.each_with_index do |sc, index|
          key = endpoint_hash_key(sc, index)
          target_hashes += scale * normalized[index]
          count = 0
          while current_hashes < target_hashes
            entries << [Zlib.crc32("#{key}_#{count}"), index]
            count += 1
            current_hashes += 1
          end
        end
        entries.sort_by! { |hash, _| hash }
        @ring_hashes = entries.map(&:first).freeze
        @ring_endpoints = entries.map(&:last).freeze
      end

      # Weight should never be zero or absent, but treating either as 1
      # (rather than letting it zero out that address's whole share of the
      # ring) is what ring_hash.cc does too.
      def endpoint_weight(subchannel)
        weight = subchannel.address.respond_to?(:weight) ? subchannel.address.weight : nil
        weight.is_a?(Integer) && weight.positive? ? weight : 1
      end

      def endpoint_hash_key(subchannel, index)
        address = subchannel.address
        return "#{address.host}:#{address.port}" if address.respond_to?(:host) && address.host
        index.to_s
      end
    end

    # gRFC A58: spreads calls across ready subchannels in proportion to
    # their weights (an EDS endpoint's load_balancing_weight, or 1 where
    # none was given) using the smooth weighted round-robin schedule LVS's
    # ipvs_wrr and nginx's upstream module both use, rather than weighted
    # random selection: over one full cycle -- @cycle_ticks calls -- every
    # address is picked exactly weight/gcd(weights) times, an exact split
    # instead of one random sampling happens to approximate.
    #
    # @api private
    class WeightedRoundRobinPolicy
      def initialize(subchannels, _args = nil)
        @subchannels = subchannels
        @weights = subchannels.map { |sc| endpoint_weight(sc) }
        gcd = @weights.reduce { |a, b| a.gcd(b) }
        @gcd = gcd.nil? || gcd.zero? ? 1 : gcd
        @max_weight = @weights.max || 1
        @cycle_ticks = @subchannels.size * (@max_weight / @gcd)
        @mu = Mutex.new
        @index = -1
        @current_weight = 0
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

      # +_hash_key+ is accepted and ignored: weighted_round_robin schedules
      # by weight, not by hashing the call.
      #
      # Every tick moves @index and @current_weight exactly as the LVS
      # algorithm does, whether or not this tick's address turns out to be
      # usable, so a dead heavy address never starves the picks that should
      # still reach a live address behind it: the loop below simply keeps
      # ticking, up to one full cycle, until it finds one that is. Nothing
      # here allocates -- @weights and @subchannels are fixed-size arrays
      # built once in #initialize.
      def pick(_hash_key = nil)
        return nil if @subchannels.empty?
        @mu.synchronize do
          picked = nil
          @cycle_ticks.times do
            advance_locked
            next unless @weights[@index] >= @current_weight
            sc = @subchannels[@index]
            next unless sc.alive?
            picked = sc
            break
          end
          picked
        end
      end

      private

      def advance_locked
        @index = (@index + 1) % @subchannels.size
        return unless @index.zero?
        @current_weight -= @gcd
        @current_weight = @max_weight if @current_weight <= 0
      end

      # Absent weight (no xDS EDS behind this address) or a non-positive one
      # defaults to 1, an equal share, rather than a weight of 0 which would
      # let @gcd become 0 and turn #advance_locked's decrement into an
      # infinite loop.
      def endpoint_weight(subchannel)
        weight = subchannel.address.respond_to?(:weight) ? subchannel.address.weight : nil
        weight.is_a?(Integer) && weight.positive? ? weight : 1
      end
    end

    # Every grpc.lb_policy_name this implementation understands.
    LB_POLICIES = {
      'pick_first' => PickFirstPolicy,
      'ring_hash' => RingHashPolicy,
      'round_robin' => RoundRobinPolicy,
      'weighted_round_robin' => WeightedRoundRobinPolicy
    }.freeze
  end
end
