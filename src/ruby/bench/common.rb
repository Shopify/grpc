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

# Shared setup for the gRPC Ruby benchmark. The server and the client
# processes both load this file.
#
# GRPC_BENCH_LIB selects which implementation to measure. It holds the
# directory that contains grpc.rb. It defaults to this checkout.

lib_dir = ENV['GRPC_BENCH_LIB']
lib_dir ||= File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(lib_dir) unless $LOAD_PATH.include?(lib_dir)

require 'grpc'

# GRPC contains the General RPC module.
module GRPC
  # Bench holds the service and the helpers that the benchmark processes
  # share.
  module Bench
    # A payload that marshals to itself. The benchmark measures the RPC
    # path, so protobuf stays out of it.
    class Blob
      attr_reader :bytes

      def initialize(bytes)
        @bytes = bytes
      end

      def self.marshal(blob)
        blob.bytes
      end

      def self.unmarshal(bytes)
        new(bytes)
      end
    end

    # How many messages a streaming call carries, and how large each one is.
    STREAM_MESSAGES = Integer(ENV.fetch('GRPC_BENCH_STREAM_MESSAGES', '1000'))
    STREAM_MESSAGE_BYTES =
      Integer(ENV.fetch('GRPC_BENCH_STREAM_MESSAGE_BYTES', '1024'))
    STREAM_MESSAGE = ('x' * STREAM_MESSAGE_BYTES).freeze
    LARGE_MESSAGE_BYTES =
      Integer(ENV.fetch('GRPC_BENCH_LARGE_MESSAGE_BYTES', '65536'))

    # The service the benchmark drives. Every method is trivial, so the
    # numbers describe the transport and not the handler.
    class Service
      include GRPC::GenericService
      self.marshal_class_method = :marshal
      self.unmarshal_class_method = :unmarshal
      self.service_name = 'grpc.bench.Bench'

      rpc :unary, Blob, Blob
      rpc :server_stream, Blob, stream(Blob)
      rpc :client_stream, stream(Blob), Blob

      def unary(request, _call)
        request
      end

      def server_stream(_request, _call)
        Enumerator.new do |yielder|
          STREAM_MESSAGES.times { yielder << Blob.new(STREAM_MESSAGE) }
        end
      end

      # A client-streaming handler receives only the call.
      def client_stream(call)
        count = 0
        call.each_remote_read { |_| count += 1 }
        Blob.new(count.to_s)
      end
    end

    Stub = Service.rpc_stub_class

    module_function

    # Returns the elapsed milliseconds of each of +iterations+ runs.
    def measure(iterations)
      samples = Array.new(iterations)
      iterations.times do |i|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
        samples[i] =
          (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
      end
      samples
    end

    def percentiles(samples)
      sorted = samples.sort
      at = lambda do |quantile|
        sorted[[(sorted.length * quantile).floor, sorted.length - 1].min]
      end
      { p50: at.call(0.50).round(3), p90: at.call(0.90).round(3),
        p99: at.call(0.99).round(3), max: sorted.last.round(3) }
    end

    # Resident set size of this process, in kilobytes.
    def rss_kb
      `ps -o rss= -p #{Process.pid}`.to_i
    rescue StandardError
      0
    end
  end
end
