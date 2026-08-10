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
require 'socket'

# grpc_proxy/https_proxy/http_proxy were read by C-core and ignored here, so a
# channel behind a corporate proxy connected straight past it (and usually
# just failed to resolve the internal-only target). CONNECT tunnelling makes
# that configuration work the same way it does in every other gRPC language.
ENV_VARS = %w[grpc_proxy https_proxy http_proxy no_grpc_proxy no_proxy].freeze
Target = GRPC::Core::Transport::Target
describe 'HTTP CONNECT proxy' do
  around(:each) do |example|
    saved = ENV_VARS.to_h { |name| [name, ENV[name]] }
    begin
      example.run
    ensure
      saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    end
  end

  # Runs a bare TCP server that plays proxy for exactly one connection:
  # captures the request bytes up to the blank line, then replies with
  # +response+. Returns the server (for the port) and a thread whose #value
  # is the accepted connection, still open, once the client has connected.
  def fake_proxy(response)
    server = TCPServer.new('127.0.0.1', 0)
    captured = +''
    thread = Thread.new do
      conn = server.accept
      captured << conn.readpartial(4096) until captured.end_with?("\r\n\r\n")
      conn.write(response)
      conn
    end
    [server, thread, captured]
  end

  def close_proxy(server, thread)
    thread.value.close
    server.close
  end

  describe 'the wire request' do
    it 'sends exactly the CONNECT request gRPC sends, nothing else' do
      server, thread, captured = fake_proxy("HTTP/1.1 200 Connection Established\r\n\r\n")
      ENV['http_proxy'] = "http://127.0.0.1:#{server.addr[1]}"

      target = Target.new(:tcp, 'backend.internal', 443, nil)
      socket, peer, = GRPC::Core::Transport.connect(target, nil, nil, args: {})
      socket.close
      close_proxy(server, thread)

      expect(captured).to eq(
        "CONNECT backend.internal:443 HTTP/1.1\r\n" \
        "Host: backend.internal:443\r\n" \
        "\r\n"
      )
      # The peer the caller sees is still the real target, not the proxy.
      expect(peer).to eq('ipv4:backend.internal:443')
    end

    it 'adds a Proxy-Authorization header for user:password@ in the proxy URL' do
      server, thread, captured = fake_proxy("HTTP/1.1 200 OK\r\n\r\n")
      ENV['http_proxy'] = "http://alice:s3cret@127.0.0.1:#{server.addr[1]}"

      target = Target.new(:tcp, 'backend.internal', 443, nil)
      socket, = GRPC::Core::Transport.connect(target, nil, nil, args: {})
      socket.close
      close_proxy(server, thread)

      expected = ['alice:s3cret'].pack('m0')
      expect(captured).to include("Proxy-Authorization: Basic #{expected}\r\n")
    end
  end

  describe 'a non-2xx CONNECT response' do
    it 'fails with an error naming the proxy and the status line' do
      server, thread, = fake_proxy("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n")
      port = server.addr[1]
      ENV['http_proxy'] = "http://127.0.0.1:#{port}"
      target = Target.new(:tcp, 'backend.internal', 443, nil)
      expect { GRPC::Core::Transport.connect(target, nil, nil, args: {}) }.to raise_error(
        /127\.0\.0\.1:#{port}.*407 Proxy Authentication Required/m
      )
      close_proxy(server, thread)
    end
  end

  describe 'proxy selection' do
    let(:target) { Target.new(:tcp, 'example.com', 443, nil) }

    it 'prefers grpc_proxy over https_proxy and http_proxy' do
      ENV['http_proxy'] = 'http://from-http:1'
      ENV['https_proxy'] = 'http://from-https:2'
      ENV['grpc_proxy'] = 'http://from-grpc:3'
      proxy = GRPC::Core::Transport.proxy_for(target, {})
      expect(proxy.host).to eq('from-grpc')
    end

    it 'falls back to https_proxy when grpc_proxy is unset' do
      ENV['http_proxy'] = 'http://from-http:1'
      ENV['https_proxy'] = 'http://from-https:2'
      proxy = GRPC::Core::Transport.proxy_for(target, {})
      expect(proxy.host).to eq('from-https')
    end

    it 'falls back to http_proxy when nothing else is set' do
      ENV['http_proxy'] = 'http://from-http:1'
      proxy = GRPC::Core::Transport.proxy_for(target, {})
      expect(proxy.host).to eq('from-http')
    end

    it 'uses no proxy when none of the environment variables are set' do
      expect(GRPC::Core::Transport.proxy_for(target, {})).to be_nil
    end

    it 'never proxies a unix target' do
      ENV['http_proxy'] = 'http://from-http:1'
      unix_target = GRPC::Core::Transport.parse_target('unix:/tmp/http_proxy_spec.sock')
      expect(GRPC::Core::Transport.proxy_for(unix_target, {})).to be_nil
    end

    it 'disables proxying when grpc.enable_http_proxy is 0' do
      ENV['http_proxy'] = 'http://from-http:1'
      args = { 'grpc.enable_http_proxy' => 0 }
      expect(GRPC::Core::Transport.proxy_for(target, args)).to be_nil
    end

    it 'still proxies when grpc.enable_http_proxy is set to a nonzero value' do
      ENV['http_proxy'] = 'http://from-http:1'
      args = { 'grpc.enable_http_proxy' => 1 }
      expect(GRPC::Core::Transport.proxy_for(target, args)).to_not be_nil
    end
  end

  describe 'no_proxy' do
    before(:each) { ENV['http_proxy'] = 'http://the-proxy:8080' }

    it 'excludes an exact host match' do
      ENV['no_proxy'] = 'example.com'
      target = Target.new(:tcp, 'example.com', 443, nil)
      expect(GRPC::Core::Transport.proxy_for(target, {})).to be_nil
    end

    it 'excludes a subdomain of a listed host' do
      ENV['no_proxy'] = 'example.com'
      target = Target.new(:tcp, 'sub.example.com', 443, nil)
      expect(GRPC::Core::Transport.proxy_for(target, {})).to be_nil
    end

    it 'does not exclude a host that merely shares a suffix' do
      ENV['no_proxy'] = 'example.com'
      target = Target.new(:tcp, 'notexample.com', 443, nil)
      expect(GRPC::Core::Transport.proxy_for(target, {})).to_not be_nil
    end

    it 'checks every comma-separated entry, not just the first' do
      ENV['no_proxy'] = 'other.test, example.com'
      target = Target.new(:tcp, 'example.com', 443, nil)
      expect(GRPC::Core::Transport.proxy_for(target, {})).to be_nil
    end

    it 'prefers no_grpc_proxy over no_proxy' do
      ENV['no_grpc_proxy'] = 'other.test'
      ENV['no_proxy'] = 'example.com'
      target = Target.new(:tcp, 'example.com', 443, nil)
      expect(GRPC::Core::Transport.proxy_for(target, {})).to_not be_nil
    end

    it 'still proxies a host not on the no_proxy list' do
      ENV['no_proxy'] = 'other.test'
      target = Target.new(:tcp, 'example.com', 443, nil)
      expect(GRPC::Core::Transport.proxy_for(target, {})).to_not be_nil
    end
  end

  describe 'the channel argument' do
    it 'is accepted by ChannelArgs' do
      expect { GRPC::Core::ChannelArgs.normalize('grpc.enable_http_proxy' => 0) }
        .to_not raise_error
    end
  end
end
