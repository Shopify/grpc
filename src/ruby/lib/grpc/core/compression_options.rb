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
    # CompressionOptions builds the channel-argument hash that conveys a
    # client or server's compression preferences. It is a pure-Ruby
    # replacement for the C extension type of the same name and mirrors the
    # grpc_compression_options struct from gRPC core.
    class CompressionOptions
      # Maps the readable name of each compression algorithm to its integer
      # value, matching the grpc_compression_algorithm enum: identity=0,
      # deflate=1, gzip=2. Order matters for #disabled_algorithms.
      ALGORITHM_VALUES = { identity: 0, deflate: 1, gzip: 2 }.freeze

      # Inverse of ALGORITHM_VALUES, ordered by ascending enum value so that
      # iterating it reproduces the C loop over grpc_compression_algorithm.
      ALGORITHM_NAMES = [:identity, :deflate, :gzip].freeze

      # Maps each compression level name to its integer value, matching the
      # grpc_compression_level enum: none=0, low=1, medium=2, high=3.
      LEVEL_VALUES = { none: 0, low: 1, medium: 2, high: 3 }.freeze

      # All three algorithms enabled by default, mirroring
      # grpc_compression_options_init which sets
      # enabled_algorithms_bitset = (1 << GRPC_COMPRESS_ALGORITHMS_COUNT) - 1.
      DEFAULT_ENABLED_ALGORITHMS_BITSET = 0x7

      # Channel-argument keys, matching the gRPC core string constants.
      CHANNEL_ARG_DEFAULT_LEVEL = 'grpc.default_compression_level'
      CHANNEL_ARG_DEFAULT_ALGORITHM = 'grpc.default_compression_algorithm'
      CHANNEL_ARG_ENABLED_ALGORITHMS_BITSET = 'grpc.compression_enabled_algorithms_bitset'

      # Creates a new, immutable CompressionOptions.
      #
      # call-seq:
      #   CompressionOptions.new(default_algorithm: :gzip,
      #                          default_level: :low,
      #                          disabled_algorithms: [:deflate])
      #
      # A single positional argument, or more than one argument, raises
      # ArgumentError, matching the C extension which only accepts an
      # optional hash.
      def initialize(default_algorithm: nil, default_level: nil, disabled_algorithms: [])
        @default_algorithm = validate_algorithm(default_algorithm) if default_algorithm
        @default_level = validate_level(default_level) if default_level

        bitset = DEFAULT_ENABLED_ALGORITHMS_BITSET
        disabled = disabled_algorithms || []
        disabled.each do |name|
          bitset &= ~(1 << algorithm_value!(name))
        end
        @enabled_algorithms_bitset = bitset

        # Derive the disabled-algorithm list from the bitset, iterating in
        # enum order, exactly as the C getter does.
        @disabled_algorithms = ALGORITHM_NAMES.each_with_object([]) do |name, acc|
          acc << name unless algorithm_enabled?(name)
        end.freeze
      end

      # The default compression algorithm as a Symbol, or nil when unset.
      attr_reader :default_algorithm

      # The default compression level as a Symbol, or nil when unset.
      attr_reader :default_level

      # The disabled algorithms as an Array of Symbols in enum order. A
      # fresh copy is returned so callers cannot mutate internal state.
      def disabled_algorithms
        @disabled_algorithms.dup
      end

      # Returns true when the named algorithm is enabled, false otherwise.
      # Raises ArgumentError for any name that is not one of :identity,
      # :deflate, :gzip.
      def algorithm_enabled?(name)
        value = algorithm_value!(name)
        (@enabled_algorithms_bitset & (1 << value)) != 0
      end

      # Returns the channel-argument Hash corresponding to these compression
      # settings. The bitset key is always present; the default-algorithm and
      # default-level keys are present only when set.
      def to_hash
        hash = {}
        hash[CHANNEL_ARG_DEFAULT_LEVEL] = LEVEL_VALUES[@default_level] if @default_level
        hash[CHANNEL_ARG_DEFAULT_ALGORITHM] = ALGORITHM_VALUES[@default_algorithm] if @default_algorithm
        hash[CHANNEL_ARG_ENABLED_ALGORITHMS_BITSET] = @enabled_algorithms_bitset
        hash
      end

      # Alias of #to_hash.
      alias to_channel_arg_hash to_hash

      # A human-readable representation that never raises.
      def to_s
        "#<#{self.class.name} default_algorithm=#{@default_algorithm.inspect} " \
          "default_level=#{@default_level.inspect} " \
          "disabled_algorithms=#{@disabled_algorithms.inspect}>"
      end

      private

      # Resolves an algorithm name to its integer value, raising
      # ArgumentError for anything that is not one of the three known
      # algorithm Symbols.
      def algorithm_value!(name)
        value = ALGORITHM_VALUES[name]
        fail ArgumentError, "Invalid compression algorithm name: #{name}" unless value

        value
      end

      # Validates an algorithm name passed to the constructor, raising
      # ArgumentError for an unknown name.
      def validate_algorithm(name)
        algorithm_value!(name)
        name
      end

      # Validates a compression level name, raising ArgumentError for an
      # unknown name. Returns the name unchanged.
      def validate_level(name)
        fail ArgumentError, "Invalid compression level name: #{name}" unless LEVEL_VALUES[name]

        name
      end
    end
  end
end
