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

require 'openssl'
require 'socket'

module GRPC
  module Core
    # Target parsing plus socket and TLS setup. Replaces the parts of C-core
    # that turn a target string and a set of credentials into a connected
    # endpoint.
    #
    # @api private
    module Transport
      ALPN = %w[h2].freeze
      DEFAULT_CONNECT_TIMEOUT = 20

      # scheme is :tcp or :unix.
      Target = Struct.new(:scheme, :host, :port, :path) do
        def to_peer
          return "unix:#{path}" if scheme == :unix
          family = host.include?(':') ? 'ipv6' : 'ipv4'
          "#{family}:#{host}:#{port}"
        end
      end

      module_function

      # Understands the target forms grpc-ruby users actually pass: a bare
      # host:port, the dns:, ipv4:, ipv6: and unix: schemes, and bracketed
      # IPv6 literals.
      def parse_target(target)
        str = target.to_s
        return Target.new(:unix, nil, nil, unix_path(str)) if str.start_with?('unix:')
        str = strip_scheme(str)
        host, port = split_host_port(str)
        Target.new(:tcp, host, port, nil)
      end

      def unix_path(str)
        rest = str.delete_prefix('unix:')
        rest = rest.delete_prefix('//') if rest.start_with?('///')
        rest
      end

      def strip_scheme(str)
        %w[dns: ipv4: ipv6:].each do |scheme|
          next unless str.start_with?(scheme)
          rest = str.delete_prefix(scheme)
          # dns:///host:port and dns://authority/host:port both name the host
          # after the last slash.
          rest = rest.split('/').last.to_s if rest.start_with?('//')
          return rest
        end
        str
      end

      def split_host_port(str)
        if str.start_with?('[')
          close = str.index(']')
          fail ArgumentError, "bad target: #{str}" if close.nil?
          host = str[1...close]
          port = str[(close + 2)..]
        else
          host, _, port = str.rpartition(':')
          if host.empty?
            host = str
            port = nil
          end
        end
        [host, port.nil? || port.empty? ? 443 : port.to_i]
      end

      # Opens a socket to +target+ and, for secure channels, completes the TLS
      # handshake with ALPN "h2".
      #
      # @return [Array(IO, String, String, nil)] socket, peer string, peer cert
      def connect(target, credentials, ssl_target_override, timeout: nil)
        socket = open_socket(target, timeout || DEFAULT_CONNECT_TIMEOUT)
        peer = target.to_peer
        return [socket, peer, nil] if credentials.nil?
        ssl = client_handshake(socket, credentials, target, ssl_target_override)
        [ssl, peer, ssl.peer_cert&.to_pem]
      end

      def open_socket(target, timeout)
        if target.scheme == :unix
          UNIXSocket.new(target.path)
        else
          socket = Socket.tcp(target.host, target.port, connect_timeout: timeout)
          socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
          socket
        end
      end

      def client_handshake(socket, credentials, target, ssl_target_override)
        context = OpenSSL::SSL::SSLContext.new
        context.alpn_protocols = ALPN
        context.verify_mode = OpenSSL::SSL::VERIFY_PEER
        context.verify_hostname = true
        context.cert_store = client_cert_store(credentials)
        if credentials.pem_private_key && credentials.pem_cert_chain
          context.key = OpenSSL::PKey.read(credentials.pem_private_key)
          context.cert = OpenSSL::X509::Certificate.new(credentials.pem_cert_chain)
        end
        ssl = OpenSSL::SSL::SSLSocket.new(socket, context)
        ssl.hostname = ssl_target_override || target.host
        ssl.sync_close = true
        ssl.connect
        unless ssl.alpn_protocol == 'h2'
          ssl.close
          fail OpenSSL::SSL::SSLError,
               "server did not negotiate h2 (got #{ssl.alpn_protocol.inspect})"
        end
        ssl
      end

      def client_cert_store(credentials)
        store = OpenSSL::X509::Store.new
        roots = credentials.pem_root_certs || ChannelCredentials.default_roots_pem
        if roots.nil? || roots.empty?
          store.set_default_paths
        else
          add_pem_certs(store, roots)
        end
        store
      end

      def add_pem_certs(store, pem)
        pem.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m)
           .each do |block|
          store.add_cert(OpenSSL::X509::Certificate.new(block))
        rescue OpenSSL::X509::StoreError
          # Duplicate roots are not an error; grpc tolerates them too.
          nil
        end
        store
      end

      # Builds the server side TLS context from ServerCredentials.
      def server_ssl_context(credentials)
        context = OpenSSL::SSL::SSLContext.new
        context.alpn_select_cb = lambda { |protocols|
          protocols.include?('h2') ? 'h2' : nil
        }
        pair = credentials.pem_key_certs.first
        certs = OpenSSL::X509::Certificate.load(pair[:cert_chain])
        context.cert = certs.first
        context.extra_chain_cert = certs[1..] unless certs.length < 2
        context.key = OpenSSL::PKey.read(pair[:private_key])
        if credentials.force_client_auth?
          context.verify_mode = OpenSSL::SSL::VERIFY_PEER |
                                OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT
          context.cert_store = add_pem_certs(OpenSSL::X509::Store.new,
                                             credentials.pem_root_certs.to_s)
        end
        context
      end

      # Binds a listening socket for +addr+ ("host:port"); port 0 picks one.
      #
      # @return [Array(TCPServer, Integer)] the listener and the bound port
      def listen(addr, so_reuseport: false)
        target = parse_target(addr)
        return [UNIXServer.new(target.path), 0] if target.scheme == :unix
        server = TCPServer.new(target.host, target.port)
        server.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
        if so_reuseport && Socket.const_defined?(:SO_REUSEPORT)
          server.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEPORT, 1)
        end
        [server, server.addr[1]]
      end

      def peer_of(socket)
        addr = socket.peeraddr
        family = addr[0] == 'AF_INET6' ? 'ipv6' : 'ipv4'
        "#{family}:#{addr[3]}:#{addr[1]}"
      rescue StandardError
        'unknown'
      end
    end
  end
end
