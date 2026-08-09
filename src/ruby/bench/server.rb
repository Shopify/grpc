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

# The server half of the benchmark. It prints the port it listens on, then
# serves until it is killed. run.rb starts it; you can also start it by
# hand to point another client at it.

require_relative 'common'

port = Integer(ENV.fetch('GRPC_BENCH_PORT', '0'))
pool_size = Integer(ENV.fetch('GRPC_BENCH_POOL_SIZE', '16'))

server = GRPC::RpcServer.new(pool_size: pool_size, poll_period: 1)
bound = server.add_http2_port("127.0.0.1:#{port}", :this_port_is_insecure)
server.handle(GRPC::Bench::Service)
Thread.new { server.run }
server.wait_till_running

puts "port=#{bound}"
$stdout.flush
sleep
