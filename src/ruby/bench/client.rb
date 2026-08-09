#!/usr/bin/env ruby
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

# The client half of the benchmark. It runs every scenario against the
# server at GRPC_BENCH_PORT and prints one JSON object on stdout.

require_relative 'common'
require 'json'

include GRPC::Bench # rubocop:disable Style/MixinUsage

PORT = Integer(ENV.fetch('GRPC_BENCH_PORT'))
TARGET = "127.0.0.1:#{PORT}".freeze
WARMUP = Integer(ENV.fetch('GRPC_BENCH_WARMUP', '200'))
UNARY_ITERS = Integer(ENV.fetch('GRPC_BENCH_UNARY_ITERS', '2000'))
LARGE_ITERS = Integer(ENV.fetch('GRPC_BENCH_LARGE_ITERS', '500'))
STREAM_ITERS = Integer(ENV.fetch('GRPC_BENCH_STREAM_ITERS', '20'))
THREADS = Integer(ENV.fetch('GRPC_BENCH_THREADS', '8'))
THREAD_ITERS = Integer(ENV.fetch('GRPC_BENCH_THREAD_ITERS', '400'))

def new_stub
  Stub.new(TARGET, :this_channel_is_insecure)
end

def qps(iterations, samples)
  (iterations / (samples.sum / 1000.0)).round
end

def mib_per_s(bytes, samples)
  (bytes / (samples.sum / 1000.0) / (1024 * 1024)).round(1)
end

stub = new_stub
results = {}
empty = Blob.new('')

# Sequential unary with an empty payload: pure round-trip cost.
WARMUP.times { stub.unary(empty) }
samples = measure(UNARY_ITERS) { stub.unary(empty) }
results['unary_empty'] = percentiles(samples).merge(
  qps: qps(UNARY_ITERS, samples), iterations: UNARY_ITERS)

# Sequential unary with a large payload: bulk throughput.
large = Blob.new('y' * LARGE_MESSAGE_BYTES)
[WARMUP / 4, 1].max.times { stub.unary(large) }
samples = measure(LARGE_ITERS) { stub.unary(large) }
results['unary_large'] = percentiles(samples).merge(
  qps: qps(LARGE_ITERS, samples),
  message_bytes: LARGE_MESSAGE_BYTES,
  # Every iteration moves the payload in both directions.
  mib_per_s: mib_per_s(LARGE_ITERS * LARGE_MESSAGE_BYTES * 2, samples))

# Concurrent unary: how well the transport shares one process.
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
concurrent = THREADS.times.map do
  Thread.new do
    thread_stub = new_stub
    measure(THREAD_ITERS) { thread_stub.unary(empty) }
  end
end.flat_map(&:value)
wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
results['unary_concurrent'] = percentiles(concurrent).merge(
  qps: ((THREADS * THREAD_ITERS) / wall).round, threads: THREADS)

stream_bytes = STREAM_MESSAGES * STREAM_MESSAGE_BYTES

# Server streaming: the server sends STREAM_MESSAGES messages.
stub.server_stream(empty).each { |_| nil }
samples = measure(STREAM_ITERS) do
  received = 0
  stub.server_stream(empty).each { received += 1 }
  fail "short stream: #{received}" unless received == STREAM_MESSAGES
end
results['server_stream'] = percentiles(samples).merge(
  messages_per_s: ((STREAM_ITERS * STREAM_MESSAGES) / (samples.sum / 1000.0)).round,
  mib_per_s: mib_per_s(STREAM_ITERS * stream_bytes, samples))

# Client streaming: the client sends STREAM_MESSAGES messages.
samples = measure(STREAM_ITERS) do
  stub.client_stream(
    Enumerator.new do |yielder|
      STREAM_MESSAGES.times { yielder << Blob.new(STREAM_MESSAGE) }
    end)
end
results['client_stream'] = percentiles(samples).merge(
  messages_per_s: ((STREAM_ITERS * STREAM_MESSAGES) / (samples.sum / 1000.0)).round,
  mib_per_s: mib_per_s(STREAM_ITERS * stream_bytes, samples))

results['client_rss_kb'] = rss_kb
results['yjit'] = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
puts JSON.generate(results)
