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

require 'spec_helper'

# A server that answers an RPC and then drops the connection in the same breath
# is the ordinary shape of a graceful shutdown: the trailers and the GOAWAY
# reach the client in one segment. The status the server sent is the final word
# on the call. A close arriving behind it must not turn a completed RPC into
# UNAVAILABLE, and a close arriving without any status must still be reported.
describe 'a status that arrives just before the transport closes' do
  before(:each) do
    @server = GRPC::Core::Server.new({})
    port = @server.add_http2_port('0.0.0.0:0', :this_port_is_insecure)
    @server.start
    @ch = GRPC::Core::Channel.new("0.0.0.0:#{port}", nil,
                                  :this_channel_is_insecure)
  end

  after(:each) do
    @server.close
  end

  # Sends a request and half-closes, then hands back both ends of the call.
  def start_call
    client_call = @ch.create_call(nil, nil, 'phony_method', nil, Time.now + 10)
    client_call.run_batch(
      GRPC::Core::CallOps::SEND_INITIAL_METADATA => {},
      GRPC::Core::CallOps::SEND_MESSAGE => 'request',
      GRPC::Core::CallOps::SEND_CLOSE_FROM_CLIENT => nil)
    [client_call, @server.request_call.call]
  end

  # Blocks until the client end has seen the transport go, so that the status
  # is resolved against a connection that is already known to be dead. Without
  # this the reader thread may not have reached the GOAWAY yet, and the test
  # would pass for the wrong reason.
  def wait_for_transport_close
    limit = Time.now + 5
    until @ch.connectivity_state != GRPC::Core::ConnectivityStates::READY
      fail 'transport never closed' if Time.now > limit
      sleep 0.001
    end
  end

  it 'reports the status the server sent, not the close behind it' do
    client_call, server_call = start_call
    server_call.run_batch(
      GRPC::Core::CallOps::SEND_INITIAL_METADATA => {},
      GRPC::Core::CallOps::SEND_MESSAGE => 'reply',
      GRPC::Core::CallOps::SEND_STATUS_FROM_SERVER =>
        Struct::Status.new(GRPC::Core::StatusCodes::OK, 'all good', {}))
    # Tear the transport down before the client has read a single frame, so
    # the response and the GOAWAY are waiting together when it does.
    @server.close
    wait_for_transport_close

    batch = client_call.run_batch(
      GRPC::Core::CallOps::RECV_INITIAL_METADATA => nil,
      GRPC::Core::CallOps::RECV_MESSAGE => nil,
      GRPC::Core::CallOps::RECV_STATUS_ON_CLIENT => nil)
    expect(batch.message).to eq('reply')
    expect(batch.status.code).to eq(GRPC::Core::StatusCodes::OK)
    expect(batch.status.details).to eq('all good')
  end

  it 'keeps a non-OK status the server sent' do
    client_call, server_call = start_call
    server_call.run_batch(
      GRPC::Core::CallOps::SEND_INITIAL_METADATA => {},
      GRPC::Core::CallOps::SEND_STATUS_FROM_SERVER =>
        Struct::Status.new(GRPC::Core::StatusCodes::PERMISSION_DENIED, 'nope', {}))
    @server.close
    wait_for_transport_close

    batch = client_call.run_batch(
      GRPC::Core::CallOps::RECV_INITIAL_METADATA => nil,
      GRPC::Core::CallOps::RECV_STATUS_ON_CLIENT => nil)
    expect(batch.status.code).to eq(GRPC::Core::StatusCodes::PERMISSION_DENIED)
    expect(batch.status.details).to eq('nope')
  end

  it 'reports UNAVAILABLE when the transport closes with no status' do
    client_call, = start_call
    # The server never answers; dropping the connection is all the client gets.
    @server.close
    wait_for_transport_close

    batch = client_call.run_batch(
      GRPC::Core::CallOps::RECV_INITIAL_METADATA => nil,
      GRPC::Core::CallOps::RECV_STATUS_ON_CLIENT => nil)
    expect(batch.status.code).to eq(GRPC::Core::StatusCodes::UNAVAILABLE)
  end
end
