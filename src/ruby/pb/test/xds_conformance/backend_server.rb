# frozen_string_literal: true

# Copyright 2026 gRPC authors.
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

require_relative '../../src/proto/grpc/testing/test_services_pb'

# A grpc.testing.TestService backend that stamps its own name into the
# 'hostname' initial metadata of every response. xds_client.rb reads
# exactly that key (op.metadata['hostname'] in execute_rpc_in_thread) to
# attribute each RPC to the backend that served it, so this is the minimum
# a backend needs to implement to be counted by LoadBalancerStatsService.
class XdsConformanceBackend < Grpc::Testing::TestService::Service
  include Grpc::Testing

  def initialize(name)
    super()
    @name = name
  end

  def empty_call(_empty, call)
    call.metadata_to_send['hostname'] = @name
    Empty.new
  end

  def unary_call(_req, call)
    call.metadata_to_send['hostname'] = @name
    SimpleResponse.new
  end
end

# Runs an XdsConformanceBackend as an insecure TestService server on an
# ephemeral port, matching the "real backend instance" side of
# run_xds_tests.py's GCE instance groups.
class XdsConformanceBackendServer
  attr_reader :name, :port

  def initialize(name)
    @name = name
    @server = GRPC::RpcServer.new(poll_period: 1)
    @port = @server.add_http2_port('127.0.0.1:0', :this_port_is_insecure)
    @server.handle(XdsConformanceBackend.new(name))
    @thread = Thread.new { @server.run }
    @server.wait_till_running
  end

  def address
    "127.0.0.1:#{@port}"
  end

  def stop
    @server.stop
    @thread.join(5)
  end
end
