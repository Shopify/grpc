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

require 'stringio'
require 'zlib'

module GRPC
  module Core
    # MessageCompression is a small pure-Ruby codec used by the transport for
    # gRPC message framing. It compresses and decompresses message payloads
    # according to the algorithm named in the grpc-encoding header.
    module MessageCompression
      # The wire names of the compression algorithms supported by gRPC
      # message framing, as they appear in the grpc-encoding header.
      SUPPORTED = %w[identity deflate gzip].freeze

      # Returns true when the given wire name is a supported algorithm.
      # Matching is case-sensitive.
      def self.supported?(name)
        SUPPORTED.include?(name)
      end

      # Compresses +binary+ using the named algorithm and returns the
      # compressed bytes as an ASCII-8BIT String. 'identity' returns the
      # input unchanged. Raises ArgumentError for an unknown algorithm.
      def self.compress(name, binary)
        case name
        when 'identity'
          binary
        when 'gzip'
          gzip_compress(binary)
        when 'deflate'
          force_binary(Zlib::Deflate.deflate(binary))
        else
          fail ArgumentError, "Unsupported compression algorithm: #{name.inspect}"
        end
      end

      # Decompresses +binary+ using the named algorithm and returns the
      # original bytes as an ASCII-8BIT String. 'identity' returns the input
      # unchanged. Raises ArgumentError for an unknown algorithm.
      def self.decompress(name, binary)
        case name
        when 'identity'
          binary
        when 'gzip'
          gzip_decompress(binary)
        when 'deflate'
          force_binary(Zlib::Inflate.inflate(binary))
        else
          fail ArgumentError, "Unsupported compression algorithm: #{name.inspect}"
        end
      end

      class << self
        private

        # Produces a gzip stream from +binary+ using Zlib::GzipWriter over a
        # StringIO buffer.
        def gzip_compress(binary)
          io = StringIO.new.set_encoding(Encoding::ASCII_8BIT)
          writer = Zlib::GzipWriter.new(io)
          begin
            writer.write(binary)
          ensure
            writer.close
          end
          force_binary(io.string)
        end

        # Reads a gzip stream produced by #gzip_compress back into the
        # original bytes.
        def gzip_decompress(binary)
          reader = Zlib::GzipReader.new(StringIO.new(binary))
          begin
            force_binary(reader.read)
          ensure
            reader.close
          end
        end

        # Ensures the returned String is ASCII-8BIT (binary) without copying
        # when it already is.
        def force_binary(string)
          string.force_encoding(Encoding::ASCII_8BIT)
        end
      end
    end
  end
end
