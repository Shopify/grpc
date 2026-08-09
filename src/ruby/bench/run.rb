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

# Runs the gRPC Ruby benchmark and prints a table.
#
#   ruby src/ruby/bench/run.rb
#   ruby src/ruby/bench/run.rb --baseline /path/to/other/grpc/lib
#
# With --baseline the runner measures all four server and client pairings,
# which separates the cost of the send path from the cost of the receive
# path. See README.md.

require 'json'
require 'optparse'
require 'socket'

BENCH_DIR = __dir__
SELF_LIB = File.expand_path('../lib', BENCH_DIR)

options = { baseline: nil, json: false, yjit: true }
OptionParser.new do |opts|
  opts.banner = 'Usage: run.rb [options]'
  opts.on('--baseline PATH',
          'directory holding the grpc.rb to compare against') do |path|
    options[:baseline] = File.expand_path(path)
  end
  opts.on('--json', 'print raw JSON instead of a table') do
    options[:json] = true
  end
  # YJIT is on by default, because that is how the implementations are
  # meant to be compared. It changes the pure Ruby numbers a great deal
  # and the C extension numbers very little.
  opts.on('--[no-]yjit', 'run the benchmark under YJIT (default: on)') do |on|
    options[:yjit] = on
  end
end.parse!

if options[:baseline] && !File.exist?(File.join(options[:baseline], 'grpc.rb'))
  abort "no grpc.rb under #{options[:baseline]}"
end

impls = { 'self' => SELF_LIB }
impls['baseline'] = options[:baseline] if options[:baseline]

# The interpreter flag that decides YJIT for a benchmark process.
#
# It goes on the command line rather than into RUBY_YJIT_ENABLE, because a
# command line flag also overrides an inherited RUBYOPT=--yjit. Clearing
# the environment variable would not.
def jit_arg(yjit)
  yjit ? '--yjit' : '--disable-yjit'
end

# Starts the benchmark server and returns [pid, port].
def start_server(lib, yjit)
  read, write = IO.pipe
  pid = Process.spawn({ 'GRPC_BENCH_LIB' => lib },
                      RbConfig.ruby, jit_arg(yjit),
                      File.join(BENCH_DIR, 'server.rb'),
                      out: write, err: File::NULL)
  write.close
  line = read.gets
  read.close
  raise 'benchmark server did not report a port' if line.nil?
  [pid, Integer(line[/port=(\d+)/, 1])]
end

def stop_server(pid)
  Process.kill('TERM', pid)
  Process.wait(pid)
rescue Errno::ESRCH, Errno::ECHILD
  nil
end

def rss_kb(pid)
  `ps -o rss= -p #{pid}`.to_i
rescue StandardError
  0
end

def run_pair(server_lib, client_lib, yjit)
  pid, port = start_server(server_lib, yjit)
  begin
    output = IO.popen({ 'GRPC_BENCH_LIB' => client_lib,
                        'GRPC_BENCH_PORT' => port.to_s },
                      [RbConfig.ruby, jit_arg(yjit),
                       File.join(BENCH_DIR, 'client.rb')],
                      err: File::NULL, &:read)
    raise 'benchmark client produced no output' if output.to_s.strip.empty?
    JSON.parse(output).merge('server_rss_kb' => rss_kb(pid))
  ensure
    stop_server(pid)
  end
end

rows = impls.keys.product(impls.keys).map do |server, client|
  warn "running server=#{server} client=#{client}"
  { 'server' => server, 'client' => client }
    .merge(run_pair(impls.fetch(server), impls.fetch(client), options[:yjit]))
end

if options[:json]
  puts JSON.pretty_generate(rows)
  exit
end

COLUMNS = [
  ['server/client', 15, ->(r) { "#{r['server']}/#{r['client']}" }],
  ['unary qps', 11, ->(r) { r.dig('unary_empty', 'qps') }],
  ['p50 ms', 9, ->(r) { format('%.3f', r.dig('unary_empty', 'p50')) }],
  ['large qps', 11, ->(r) { r.dig('unary_large', 'qps') }],
  ['large MiB/s', 13, ->(r) { r.dig('unary_large', 'mib_per_s') }],
  ['conc qps', 10, ->(r) { r.dig('unary_concurrent', 'qps') }],
  ['s-stream m/s', 14, ->(r) { r.dig('server_stream', 'messages_per_s') }],
  ['c-stream m/s', 14, ->(r) { r.dig('client_stream', 'messages_per_s') }],
  ['srv RSS MB', 12, ->(r) { (r['server_rss_kb'] / 1024.0).round }]
].freeze

puts "ruby #{RUBY_VERSION}, YJIT #{rows.first['yjit'] ? 'on' : 'off'}"
header = COLUMNS.map { |name, width, _| name.to_s.rjust(width) }.join
puts header
puts '-' * header.length
rows.each do |row|
  puts COLUMNS.map { |_, width, value| value.call(row).to_s.rjust(width) }.join
end
