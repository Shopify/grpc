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
    # Validates and normalises the channel-argument hashes that Channel and
    # Server accept. Replaces rb_channel_args.c.
    #
    # @api private
    module ChannelArgs
      SSL_TARGET_NAME_OVERRIDE = 'grpc.ssl_target_name_override'
      ENABLE_CENSUS = 'grpc.census'
      MAX_CONCURRENT_STREAMS = 'grpc.max_concurrent_streams'
      MAX_RECEIVE_MESSAGE_LENGTH = 'grpc.max_receive_message_length'
      MAX_SEND_MESSAGE_LENGTH = 'grpc.max_send_message_length'
      PRIMARY_USER_AGENT = 'grpc.primary_user_agent'
      SECONDARY_USER_AGENT = 'grpc.secondary_user_agent'
      DEFAULT_AUTHORITY = 'grpc.default_authority'
      SO_REUSEPORT = 'grpc.so_reuseport'
      KEEPALIVE_TIME_MS = 'grpc.keepalive_time_ms'
      KEEPALIVE_TIMEOUT_MS = 'grpc.keepalive_timeout_ms'
      KEEPALIVE_PERMIT_WITHOUT_CALLS = 'grpc.keepalive_permit_without_calls'
      CLIENT_IDLE_TIMEOUT_MS = 'grpc.client_idle_timeout_ms'
      MAX_CONNECTION_IDLE_MS = 'grpc.max_connection_idle_ms'
      MAX_CONNECTION_AGE_MS = 'grpc.max_connection_age_ms'
      MAX_CONNECTION_AGE_GRACE_MS = 'grpc.max_connection_age_grace_ms'
      COMPRESSION_ENABLED_ALGORITHMS_BITSET =
        'grpc.compression_enabled_algorithms_bitset'
      DEFAULT_COMPRESSION_ALGORITHM = 'grpc.default_compression_algorithm'
      DEFAULT_COMPRESSION_LEVEL = 'grpc.default_compression_level'

      # Every argument in the "grpc." namespace that this implementation
      # actually acts on. Anything else in that namespace is a gRPC argument
      # we do not implement, and accepting it silently is how a keepalive
      # setting becomes a connection that dies with no explanation. Names
      # outside the namespace belong to the caller and are ignored, which is
      # what the C extension did with them.
      HONOURED = [
        CLIENT_IDLE_TIMEOUT_MS,
        COMPRESSION_ENABLED_ALGORITHMS_BITSET,
        DEFAULT_AUTHORITY,
        DEFAULT_COMPRESSION_ALGORITHM,
        KEEPALIVE_PERMIT_WITHOUT_CALLS,
        KEEPALIVE_TIME_MS,
        KEEPALIVE_TIMEOUT_MS,
        MAX_CONCURRENT_STREAMS,
        MAX_CONNECTION_AGE_GRACE_MS,
        MAX_CONNECTION_AGE_MS,
        MAX_CONNECTION_IDLE_MS,
        MAX_RECEIVE_MESSAGE_LENGTH,
        MAX_SEND_MESSAGE_LENGTH,
        PRIMARY_USER_AGENT,
        SECONDARY_USER_AGENT,
        SO_REUSEPORT,
        SSL_TARGET_NAME_OVERRIDE
      ].freeze

      GRPC_NAMESPACE = 'grpc.'

      # gRPC's own default for both directions is 4 MiB receive, unlimited
      # send; -1 means "no limit".
      DEFAULT_MAX_RECEIVE_MESSAGE_LENGTH = 4 * 1024 * 1024

      module_function

      # Converts the user-supplied hash into a String-keyed hash whose values
      # are Strings or Integers, raising the same TypeErrors the C extension
      # raised for anything else.
      def normalize(args)
        return {} if args.nil?
        unless args.is_a?(Hash)
          fail TypeError,
               "bad channel args: got:<#{args.class}> want: a hash or nil"
        end
        out = args.each_with_object({}) do |(key, value), acc|
          acc[normalize_key(key)] = normalize_value(key, value)
        end
        reject_unimplemented(out)
        out
      end

      # Fails on a gRPC argument this implementation does not act on, rather
      # than accepting it and doing nothing.
      def reject_unimplemented(args)
        unimplemented = args.keys.select do |key|
          key.start_with?(GRPC_NAMESPACE) && !HONOURED.include?(key)
        end
        return if unimplemented.empty?
        fail ArgumentError,
             "channel argument #{unimplemented.sort.join(', ')} is not " \
             "implemented by the pure Ruby core, and ignoring it would " \
             "change behaviour silently. Implemented: #{HONOURED.join(', ')}"
      end

      # Maps grpc.default_compression_algorithm, an integer from the
      # grpc_compression_algorithm enum, to the name the transport uses.
      # Returns nil when the enabled bitset excludes that algorithm.
      def compression_algorithm(args)
        value = args[DEFAULT_COMPRESSION_ALGORITHM]
        return nil unless value.is_a?(Integer)
        name = CompressionOptions::ALGORITHM_NAMES[value]
        return nil if name.nil? || name == :identity
        bitset = int(args, COMPRESSION_ENABLED_ALGORITHMS_BITSET,
                     CompressionOptions::DEFAULT_ENABLED_ALGORITHMS_BITSET)
        return nil if (bitset & (1 << value)).zero?
        name.to_s
      end

      def normalize_key(key)
        case key
        when String then key
        when Symbol then key.to_s
        else
          fail TypeError,
               "bad chan arg: got <#{key.class}>, want <String|Symbol>"
        end
      end

      def normalize_value(key, value)
        case value
        when String then value
        when Symbol then value.to_s
        when Integer then value
        else
          fail TypeError,
               "#{key}: bad value: got <#{value.class}>, want <String|Fixnum>"
        end
      end

      # Reads a millisecond argument as seconds, which is what every timer in
      # this core works in. Returns nil when unset, and treats a non-positive
      # value as unset, as gRPC does.
      def seconds(args, key)
        ms = args[key]
        return nil unless ms.is_a?(Integer) && ms.positive?
        ms / 1000.0
      end

      # Reads an integer argument, falling back to +default+.
      def int(args, key, default)
        value = args[key]
        value.is_a?(Integer) ? value : default
      end

      # Reads a string argument, falling back to +default+.
      def str(args, key, default = nil)
        value = args[key]
        value.is_a?(String) ? value : default
      end
    end
  end
end
