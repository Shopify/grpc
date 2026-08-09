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
    # TimeSpec is a point on the real-time clock, plus the two saturating
    # values gpr_timespec used for "never" and "already past".
    #
    # It replaces the C extension class of the same name.
    class TimeSpec
      # Largest value gpr_timespec holds; matches GPR_INF_FUTURE.
      INF_FUTURE_SECS = 9_223_372_036_854_775_807
      # Smallest value gpr_timespec holds; matches GPR_INF_PAST.
      INF_PAST_SECS = -9_223_372_036_854_775_808

      # Time cannot represent 2**63 seconds, so saturate at the range the C
      # extension produced when it built a Time from the raw seconds.
      INF_FUTURE_TIME_SEC = 253_402_300_799 # 9999-12-31T23:59:59Z
      INF_PAST_TIME_SEC = -62_135_596_800   # 0001-01-01T00:00:00Z

      attr_reader :tv_sec, :tv_nsec

      def initialize(tv_sec, tv_nsec = 0)
        @tv_sec = tv_sec
        @tv_nsec = tv_nsec
        freeze
      end

      # Converts the values the surface API accepts as a deadline into a
      # TimeSpec. Mirrors grpc_rb_time_timeval(time, /* interval */ 0).
      def self.from(value)
        case value
        when TimeSpec then value
        when Time then new(value.tv_sec, value.tv_nsec)
        when Integer then new(value, 0)
        when Numeric then from_float(value.to_f)
        else
          fail TypeError,
               'bad input: (time)->c_timeval, got ' \
               "<#{value.class}>, want <secs from epoch>|<Time>|" \
               '<GRPC::TimeConst.*>'
        end
      end

      def self.from_float(float)
        return TimeConsts::INFINITE_FUTURE if float == Float::INFINITY
        return TimeConsts::INFINITE_PAST if float == -Float::INFINITY
        secs = float.floor
        new(secs, ((float - secs) * 1e9).round)
      end
      private_class_method :from_float

      def infinite_future?
        @tv_sec == INF_FUTURE_SECS
      end

      def infinite_past?
        @tv_sec == INF_PAST_SECS
      end

      # Seconds from +now+ until this deadline, or nil when it never expires.
      def to_relative_seconds(now = Time.now)
        return nil if infinite_future?
        return 0.0 if infinite_past?
        delta = to_f - now.to_f
        delta.negative? ? 0.0 : delta
      end

      def to_f
        return Float::INFINITY if infinite_future?
        return -Float::INFINITY if infinite_past?
        @tv_sec + (@tv_nsec / 1e9)
      end

      def to_time
        Time.at(clamped_sec, clamped_usec)
      end

      def inspect
        to_time.inspect
      end

      def to_s
        to_time.to_s
      end

      def ==(other)
        other.is_a?(TimeSpec) &&
          other.tv_sec == @tv_sec && other.tv_nsec == @tv_nsec
      end
      alias eql? ==

      def hash
        [@tv_sec, @tv_nsec].hash
      end

      private

      def clamped_sec
        return INF_FUTURE_TIME_SEC if infinite_future?
        return INF_PAST_TIME_SEC if infinite_past?
        @tv_sec
      end

      def clamped_usec
        return 0 if infinite_future? || infinite_past?
        @tv_nsec / 1000
      end
    end

    # Constants that map onto gpr's static timeval structs.
    module TimeConsts
      ZERO = TimeSpec.new(0, 0)
      INFINITE_FUTURE = TimeSpec.new(TimeSpec::INF_FUTURE_SECS, 0)
      INFINITE_PAST = TimeSpec.new(TimeSpec::INF_PAST_SECS, 0)
    end
  end
end
