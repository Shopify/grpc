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
require 'uri'

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

      # Environment variables consulted for a proxy, in priority order, and
      # for the exclusion list that overrides them. Matches gRPC's own
      # precedence so a proxy already configured for other gRPC clients on
      # this host behaves the same way here.
      PROXY_ENV_VARS = %w[grpc_proxy https_proxy http_proxy].freeze
      NO_PROXY_ENV_VARS = %w[no_grpc_proxy no_proxy].freeze

      # scheme is :tcp or :unix. +addresses+ is populated by
      # #resolve_addresses: nil until then, and afterwards the list of
      # every A/AAAA record +host+ named (each itself a :tcp Target whose
      # host is a literal address), or [self] for a :unix target.
      Target = Struct.new(:scheme, :host, :port, :path, :addresses) do
        def to_peer
          return "unix:#{path}" if scheme == :unix
          family = host.include?(':') ? 'ipv6' : 'ipv4'
          "#{family}:#{host}:#{port}"
        end
      end

      # host/port to open the TCP socket to, plus Basic-auth credentials
      # parsed out of a "user:password@" prefix on the proxy URL, if any.
      ProxyTarget = Struct.new(:host, :port, :user, :password)

      module_function

      # Understands the target forms grpc-ruby users actually pass: a bare
      # host:port, the dns:, ipv4:, ipv6: and unix: schemes, and bracketed
      # IPv6 literals.
      KNOWN_SCHEMES = %w[dns ipv4 ipv6 unix].freeze

      def parse_target(target)
        str = target.to_s
        reject_unknown_scheme(str)
        return Target.new(:unix, nil, nil, unix_path(str)) if str.start_with?('unix:')
        str = strip_scheme(str)
        host, port = split_host_port(str)
        Target.new(:tcp, host, port, nil)
      end

      # Resolves +target+'s host to every address it names -- A and AAAA
      # records alike, via the system resolver -- rather than just the one
      # a single lookup happens to return first, so an LB policy can hold a
      # subchannel per address instead of leaving that fan-out to whatever
      # Socket.tcp did internally. DNS SRV records and service config
      # published over a DNS TXT record are out of scope; this only walks
      # A/AAAA. A :unix target has nothing to resolve.
      #
      # Mutates +target.addresses+ and also returns it.
      def resolve_addresses(target)
        target.addresses = target.scheme == :unix ? [target] : dns_addresses(target)
      end

      def dns_addresses(target)
        Addrinfo.getaddrinfo(target.host, target.port, nil, :STREAM)
                .map { |ai| Target.new(:tcp, ai.ip_address, target.port, nil) }
                .uniq(&:host)
      end

      # "xds:///service" used to parse as the host "xds" on port 0, so the
      # channel was built and only failed later, connecting to a name the
      # caller never wrote. A scheme this implementation does not resolve has
      # to say so. Only the "scheme://" form is treated as a scheme, because
      # "localhost:50051" is a host and a port.
      def reject_unknown_scheme(str)
        mark = str.index('://')
        return if mark.nil?
        scheme = str[0, mark]
        return if KNOWN_SCHEMES.include?(scheme)
        fail ArgumentError,
             "unsupported target scheme #{scheme.inspect} in #{str.inspect}; " \
             "this implementation resolves #{KNOWN_SCHEMES.join(', ')}"
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

      # Opens a socket to +address+ -- the concrete endpoint an LB policy
      # picked, defaulting to +target+ itself when the caller has not
      # resolved one -- tunnelling through an HTTP CONNECT proxy first when
      # one applies, and for secure channels completes the TLS handshake
      # with ALPN "h2" over the (possibly tunnelled) socket. TLS hostname
      # verification and the CONNECT authority always use +target+, the
      # name the caller asked for, never the resolved address: a proxy or
      # peer must be able to resolve/verify the name itself.
      #
      # @return [Array(IO, String, String, nil)] socket, peer string, peer cert
      def connect(target, credentials, ssl_target_override, address: target, args: {}, timeout: nil)
        proxy = proxy_for(target, args)
        connect_target = proxy ? Target.new(:tcp, proxy.host, proxy.port, nil) : address
        socket = open_socket(connect_target, timeout || DEFAULT_CONNECT_TIMEOUT)
        connect_through_proxy(socket, proxy, target) if proxy
        peer = address.to_peer
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

      # Picks the proxy to tunnel through, honouring grpc.enable_http_proxy,
      # the grpc_proxy/https_proxy/http_proxy environment variables in that
      # order, and the no_grpc_proxy/no_proxy exclusion list. Returns nil, the
      # common case, when no proxy applies. Unix targets never proxy, mirroring
      # C-core.
      def proxy_for(target, args)
        return nil if target.scheme == :unix
        return nil if ChannelArgs.int(args, ChannelArgs::ENABLE_HTTP_PROXY, 1).zero?
        uri_str = PROXY_ENV_VARS.map { |name| ENV[name] }.find { |v| v && !v.empty? }
        return nil if uri_str.nil?
        return nil if no_proxy?(target.host)
        parse_proxy_url(uri_str)
      end

      def no_proxy?(host)
        list = NO_PROXY_ENV_VARS.map { |name| ENV[name] }.find { |v| v && !v.empty? }
        return false if list.nil?
        list.split(',').any? { |entry| no_proxy_entry_matches?(host, entry) }
      end

      # "example.com" excludes the host itself and every subdomain, matching
      # gRPC's own no_proxy semantics; a bare CIDR or IP entry is not
      # supported since this core proxies by hostname, not resolved address.
      def no_proxy_entry_matches?(host, raw_entry)
        entry = raw_entry.strip.delete_prefix('.').downcase
        return false if entry.empty?
        downcased = host.downcase
        downcased == entry || downcased.end_with?(".#{entry}")
      end

      def parse_proxy_url(str)
        uri = URI.parse(str)
        fail ArgumentError, "cannot parse proxy URI #{str.inspect}" if uri.host.nil?
        ProxyTarget.new(uri.host, uri.port, uri.user, uri.password)
      rescue URI::InvalidURIError => e
        fail ArgumentError, "cannot parse proxy URI #{str.inspect}: #{e.message}"
      end

      # Sends the CONNECT request and requires a 2xx response before handing
      # +socket+ back as a tunnel to +target+; TLS, if any, is negotiated
      # after this returns, exactly as it would be without a proxy.
      def connect_through_proxy(socket, proxy, target)
        socket.write(http_connect_request(proxy, target))
        status_line = socket.readline("\r\n")
        consume_proxy_response_headers(socket)
        return if status_line.match?(%r{\AHTTP/1\.[01] 2\d\d})
        socket.close
        fail "CONNECT to proxy #{proxy.host}:#{proxy.port} for " \
             "#{target.host}:#{target.port} failed: #{status_line.strip}"
      end

      def http_connect_request(proxy, target)
        authority = "#{target.host}:#{target.port}"
        request = +"CONNECT #{authority} HTTP/1.1\r\nHost: #{authority}\r\n"
        request << "Proxy-Authorization: Basic #{proxy_auth(proxy)}\r\n" if proxy.user
        request << "\r\n"
      end

      def proxy_auth(proxy)
        [[proxy.user, proxy.password].join(':')].pack('m0')
      end

      def consume_proxy_response_headers(socket)
        loop do
          line = socket.readline("\r\n")
          break if line == "\r\n"
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
