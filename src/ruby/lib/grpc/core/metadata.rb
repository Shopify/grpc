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

require 'base64'

module GRPC
  module Core
    # Converts between the metadata hashes the surface API uses and the header
    # lists the HTTP/2 layer carries. The validation rules and error messages
    # match rb_call.c and src/core/lib/surface/validate_metadata.cc so that
    # callers see the same failures as with the C extension.
    #
    # @api private
    module Metadata
      BINARY_SUFFIX = '-bin'
      # Keys are lowercase alphanumerics plus '-', '_' and '.'.
      LEGAL_KEY = /\A[a-z0-9\-_.]+\z/
      # Non-binary values are printable ASCII.
      LEGAL_VALUE = /\A[ -~]*\z/
      # Headers the client transport consumes rather than surfacing to the
      # application, matching what C-core hides from recv_initial_metadata.
      CLIENT_RESERVED = %w[
        content-type grpc-encoding grpc-accept-encoding
      ].freeze

      module_function

      # @param hash [Hash, nil] the user-supplied metadata
      # @return [Array<Array(String, String)>] header pairs, in hash order
      def encode(hash)
        return [] if hash.nil?
        unless hash.is_a?(Hash)
          fail TypeError, "md_ary_convert: got <#{hash.class}>, want <Hash>"
        end
        out = []
        hash.each { |key, value| encode_pair(out, key, value) }
        out
      end

      def encode_pair(out, key, value)
        name = normalize_key(key)
        binary = name.end_with?(BINARY_SUFFIX)
        case value
        when Array
          value.each { |v| out << [name, encode_value(name, v, binary)] }
        when String
          out << [name, encode_value(name, value, binary)]
        else
          fail ArgumentError, 'Header values must be of type string or array'
        end
      end

      def normalize_key(key)
        name =
          case key
          when Symbol then key.to_s
          when String then key
          else
            fail TypeError,
                 'grpc_rb_md_ary_fill_hash_cb: bad type for key parameter'
          end
        return name if LEGAL_KEY.match?(name)
        fail ArgumentError,
             "'#{name}' is an invalid header key, must match [a-z0-9-_.]+"
      end

      def encode_value(_name, value, binary)
        unless value.is_a?(String)
          fail ArgumentError, 'Header values must be of type string or array'
        end
        return Base64.strict_encode64(value) if binary
        unless LEGAL_VALUE.match?(value)
          fail ArgumentError, "Header value '#{value}' has invalid characters"
        end
        value
      end

      # @param pairs [Array<Array(String, String)>] received header pairs
      # @return [Hash] repeated keys collapse into an Array, matching the shape
      #   grpc_rb_md_ary_to_h produced
      def decode(pairs)
        pairs.each_with_object({}) do |(name, value), out|
          next if name.start_with?(':')
          decoded = name.end_with?(BINARY_SUFFIX) ? decode_binary(value) : value
          existing = out[name]
          if existing.nil?
            out[name] = decoded
          elsif existing.is_a?(Array)
            existing << decoded
          else
            out[name] = [existing, decoded]
          end
        end
      end

      # gRPC senders may omit base64 padding, so restore it before decoding.
      def decode_binary(value)
        padded = value + ('=' * ((4 - (value.bytesize % 4)) % 4))
        Base64.decode64(padded)
      rescue ArgumentError
        value
      end
    end
  end
end
