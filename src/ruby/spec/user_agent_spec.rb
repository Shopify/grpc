# Copyright 2020 gRPC authors.
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

# a test service that checks the cert of its peer
class UserAgentEchoService
  include GRPC::GenericService
  rpc :an_rpc, EchoMsg, EchoMsg

  def an_rpc(_req, call)
    EchoMsg.new(msg: call.metadata['user-agent'])
  end
end

UserAgentEchoServiceStub = UserAgentEchoService.rpc_stub_class

describe 'user agent' do
  RpcServer = GRPC::RpcServer

  before(:all) do
    server_opts = {
      poll_period: 1
    }
    @srv = new_rpc_server_for_testing(**server_opts)
    @port = @srv.add_http2_port('0.0.0.0:0', :this_port_is_insecure)
    @srv.handle(UserAgentEchoService)
    @srv_thd = Thread.new { @srv.run }
    @srv.wait_till_running
  end

  after(:all) do
    expect(@srv.stopped?).to be(false)
    @srv.stop
    @srv_thd.join
  end

  # Every stub opens its own channel, and a channel not closed keeps its
  # connection-maintenance thread running for the rest of the process. Track
  # every stub created here and close it, instead of leaking one thread per
  # stub into every spec file that runs after this one.
  after(:each) do
    (@stubs || []).each(&:close)
  end

  def new_stub(channel_args: {})
    stub = UserAgentEchoServiceStub.new("localhost:#{@port}",
                                        :this_channel_is_insecure,
                                        channel_args: channel_args)
    (@stubs ||= []) << stub
    stub
  end

  it 'client sends expected user agent' do
    stub = new_stub
    response = stub.an_rpc(EchoMsg.new)
    expected_user_agent_prefix = "grpc-ruby/#{GRPC::VERSION}"
    expect(response.msg.start_with?(expected_user_agent_prefix)).to be true
    # check that the expected user agent prefix occurs in the real user agent exactly once
    expect(response.msg.split(expected_user_agent_prefix).size).to eq 2
  end

  it 'user agent header does not grow when the same channel args hash is used across multiple stubs' do
    shared_channel_args_hash = {}
    10.times do
      stub = new_stub(channel_args: shared_channel_args_hash)
      response = stub.an_rpc(EchoMsg.new)
      puts "got echo response: #{response.msg}"
      expected_user_agent_prefix = "grpc-ruby/#{GRPC::VERSION}"
      expect(response.msg.start_with?(expected_user_agent_prefix)).to be true
      # check that the expected user agent prefix occurs in the real user agent exactly once
      expect(response.msg.split(expected_user_agent_prefix).size).to eq 2
    end
  end

  it 'closing a stub stops its channel background threads' do
    before = Thread.list.size
    stub = new_stub
    stub.an_rpc(EchoMsg.new)
    stub.close
    @stubs.delete(stub)
    sleep 0.05
    expect(Thread.list.size).to be <= before
  end
end
