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

require_relative 'rpc_stream'

module GRPC
  module Core
    module OutlierDetection
      # Per-address call outcome counts. Call#op_recv_status bumps this once
      # per finished client RPC, on whatever thread that RPC finishes on;
      # OutlierDetectionPolicy#evaluate reads and resets it once per
      # interval, from the one timer thread Channel owns. The two race: an
      # increment landing during #snapshot! can be lost. Deliberately not
      # guarded by a Mutex -- IMPLEMENTATION.md measured a mutex taken on
      # every RPC (there, for a memoized service config read) at 12 per cent
      # on the eight-thread benchmark, and outlier detection only needs an
      # approximate rate, the same trade C-core's relaxed atomics make here.
      class CallCounter
        def initialize
          @success = 0
          @failure = 0
        end

        def record(succeeded)
          succeeded ? @success += 1 : @failure += 1
        end

        # [success, failure] for the interval that just ended; starts the
        # next interval at zero so consecutive evaluations never double
        # count a call.
        def snapshot!
          success = @success
          failure = @failure
          @success = 0
          @failure = 0
          [success, failure]
        end
      end

      # One address's ejection bookkeeping, owned by OutlierDetectionPolicy.
      # Ejection itself is delegated to the Subchannel (#eject/#uneject)
      # rather than tracked here, so every LB policy's existing #alive?
      # based picking already skips an ejected address without having to
      # know outlier detection exists.
      class Tracker
        attr_reader :ejection_count

        def initialize(subchannel)
          @subchannel = subchannel
          @ejection_count = 0
          @ejected_at = nil
        end

        def ejected?
          !@ejected_at.nil?
        end

        def eject(now)
          @ejection_count += 1
          @ejected_at = now
          @subchannel.eject
        end

        # gRFC A50: base_ejection_time * ejection_count, capped at
        # max_ejection_time, so an address that keeps earning fresh
        # ejections backs off further each time instead of flapping in and
        # out on a fixed timer.
        def maybe_uneject(now, base_ejection_time, max_ejection_time)
          return unless ejected?
          duration = [base_ejection_time * @ejection_count, max_ejection_time].min
          return if now - @ejected_at < duration
          @ejected_at = nil
          @subchannel.uneject
        end

        # [success, failure] for the interval just finished. nil counts as
        # [0, 0]: an address whose Subchannel never got as far as dialing
        # (outlier_counter unset) has no calls to blame it for either way.
        def counts
          @subchannel.outlier_counter&.snapshot! || [0, 0]
        end
      end

      # A parsed `outlierDetection` service-config object. Either ejection
      # sub-message being absent from the JSON (its *_request_volume nil
      # here) disables that algorithm entirely, matching gRFC A50: an
      # algorithm only runs when its own config object was present, even if
      # empty (taking every default within it).
      Config = Struct.new(
        :interval, :base_ejection_time, :max_ejection_time, :max_ejection_percent,
        :success_rate_stdev_factor, :success_rate_enforcement_percentage,
        :success_rate_minimum_hosts, :success_rate_request_volume,
        :failure_percentage_threshold, :failure_percentage_enforcement_percentage,
        :failure_percentage_minimum_hosts, :failure_percentage_request_volume,
        keyword_init: true
      )
    end

    # Wraps a child LB policy (any LB_POLICIES entry) with gRFC A50 outlier
    # detection. Implements the same maybe_connect/connectivity_state/
    # last_error/pick interface every other LB policy does, plus #evaluate,
    # which Channel's outlier-detection timer calls once per
    # +config.interval+ -- see Channel#build_subchannels_locked and
    # #stop_outlier_detection.
    #
    # Ejection works by flipping Subchannel#eject, which #alive? already
    # honours, rather than by filtering #pick's result here: that means
    # every existing and future LB_POLICIES entry gets ejection for free
    # as long as it keeps picking through #alive?, with nothing in this
    # class needing to know how any particular policy spreads calls.
    #
    # @api private
    class OutlierDetectionPolicy
      def initialize(subchannels, child, config)
        @child = child
        @config = config
        @trackers = subchannels.map do |subchannel|
          subchannel.outlier_counter = OutlierDetection::CallCounter.new
          OutlierDetection::Tracker.new(subchannel)
        end
      end

      def maybe_connect
        @child.maybe_connect
      end

      def connectivity_state
        @child.connectivity_state
      end

      def last_error
        @child.last_error
      end

      def pick(hash_key = nil)
        @child.pick(hash_key)
      end

      # +now+ is a parameter, not always RpcStream.now, so a spec can drive
      # ejection/backoff/un-ejection deterministically instead of sleeping
      # through +interval+, +base_ejection_time+ and +max_ejection_time+.
      def evaluate(now = RpcStream.now)
        @trackers.each { |t| t.maybe_uneject(now, @config.base_ejection_time, @config.max_ejection_time) }
        return if @trackers.size < 2 # nothing to compare an address against
        stats = @trackers.map { |t| [t, *t.counts] } # [tracker, success, failure]
        eject_by_success_rate(stats, now) unless @config.success_rate_request_volume.nil?
        eject_by_failure_percentage(stats, now) unless @config.failure_percentage_request_volume.nil?
        nil
      end

      private

      # Ejects the addresses more than success_rate_stdev_factor standard
      # deviations below the mean success rate of every address with
      # enough volume to trust -- gRFC A50's "success rate" algorithm.
      def eject_by_success_rate(stats, now)
        eligible = enough_volume(stats, @config.success_rate_minimum_hosts, @config.success_rate_request_volume)
        return if eligible.nil?
        rates = eligible.map { |_, s, f| 100.0 * s / (s + f) }
        mean = rates.sum / rates.size
        stdev = Math.sqrt(rates.sum { |r| (r - mean)**2 } / rates.size)
        threshold = mean - (stdev * @config.success_rate_stdev_factor / 1000.0)
        eligible.zip(rates).sort_by { |_, rate| rate }.each do |(tracker, _s, _f), rate|
          next if rate >= threshold
          maybe_eject(tracker, now, @config.success_rate_enforcement_percentage)
        end
      end

      # Ejects any address whose failure percentage exceeds
      # failure_percentage_threshold, given enough volume -- gRFC A50's
      # "failure percentage" algorithm.
      def eject_by_failure_percentage(stats, now)
        eligible = enough_volume(stats, @config.failure_percentage_minimum_hosts,
                                 @config.failure_percentage_request_volume)
        return if eligible.nil?
        eligible.sort_by { |_, s, f| s.to_f / (s + f) }.each do |tracker, s, f|
          failure_pct = 100.0 * f / (s + f)
          next if failure_pct <= @config.failure_percentage_threshold
          maybe_eject(tracker, now, @config.failure_percentage_enforcement_percentage)
        end
      end

      # nil below minimum_hosts: gRFC A50 suppresses the whole algorithm,
      # not just individual addresses, when too few have enough data.
      def enough_volume(stats, minimum_hosts, request_volume)
        eligible = stats.reject { |_, s, f| s + f < request_volume }
        return nil if eligible.size < minimum_hosts
        eligible
      end

      # enforcement_percentage is the probability (0-100) that an address
      # meeting the ejection criteria is actually ejected this interval,
      # letting a rollout apply the algorithm's judgement gradually rather
      # than all at once.
      def maybe_eject(tracker, now, enforcement_percentage)
        return if enforcement_percentage < 100 && rand(100) >= enforcement_percentage
        return if would_exceed_max_ejection_percent?
        tracker.eject(now)
      end

      def would_exceed_max_ejection_percent?
        ejected = @trackers.count(&:ejected?)
        100.0 * (ejected + 1) / @trackers.size > @config.max_ejection_percent
      end
    end
  end
end
