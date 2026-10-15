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

require 'spec_helper'

# A client stub and its channel work from a non-main Ractor: no constant,
# module ivar or define_method body on the call path is main-only.
module RactorSpec
  Raw = Data.define(:s) do
    def self.marshal(obj) = obj.s

    def self.unmarshal(bytes) = new(bytes)
  end

  class EchoService
    include GRPC::GenericService
    self.service_name = 'ractor.Echo'
    rpc :Echo, Raw, Raw
    rpc :Count, Raw, stream(Raw)
    rpc :Chat, stream(Raw), stream(Raw)
  end

  class EchoImpl < EchoService
    def echo(req, _call) = Raw.new("echo:#{req.s}")

    def count(req, _call) = Array.new(Integer(req.s)) { |i| Raw.new(i.to_s) }

    def chat(reqs, _call) = reqs.map { |r| Raw.new(r.s.upcase) }
  end

  Stub = EchoService.rpc_stub_class
end

describe 'client calls from non-main Ractors' do
  before(:all) do
    @server = GRPC::RpcServer.new
    @port = @server.add_http2_port('127.0.0.1:0', :this_port_is_insecure)
    @server.handle(RactorSpec::EchoImpl)
    @thread = Thread.new { @server.run }
    @server.wait_till_running
  end

  after(:all) do
    @server.stop
    @thread.join
  end

  it 'makes unary, server-streaming and bidi calls from several Ractors at once' do
    ractors = Array.new(3) do |n|
      Ractor.new(@port, n) do |port, id|
        raw = RactorSpec::Raw
        stub = RactorSpec::Stub.new("127.0.0.1:#{port}", :this_channel_is_insecure)
        unary = Array.new(5) { |i| stub.echo(raw.new("#{id}-#{i}")).s }
        counted = stub.count(raw.new('3')).map(&:s)
        chat = stub.chat([raw.new('a'), raw.new('b')].each).map(&:s)
        [unary.last, counted, chat]
      end
    end
    results = ractors.map(&:value)
    expect(results).to eq(Array.new(3) { |n| ["echo:#{n}-4", %w[0 1 2], %w[A B]] })
  end
end
