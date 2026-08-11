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
require 'resolv'
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

      # scheme is :tcp, :unix or :xds. +addresses+ is populated by
      # #resolve_addresses: nil until then, and afterwards the list of
      # every A/AAAA record +host+ named (each itself a :tcp Target whose
      # host is a literal address), the endpoints an XdsClient resolved
      # for an :xds target, or [self] for a :unix target. An :xds target
      # has no real network host/port of its own -- #path carries the
      # resource name instead, and #host mirrors it so TLS hostname
      # verification has something to check when no override is given.
      # +weight+ is nil except for an EDS-resolved :xds endpoint, where it
      # carries the LbEndpoint's load_balancing_weight for the
      # ring_hash/weighted_round_robin LB policies; every other resolver
      # leaves it nil and those policies treat that as weight 1.
      Target = Struct.new(:scheme, :host, :port, :path, :addresses, :weight) do
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
      # host:port, the dns:, ipv4:, ipv6:, unix: and xds: schemes, and
      # bracketed IPv6 literals.
      KNOWN_SCHEMES = %w[dns ipv4 ipv6 unix xds].freeze

      def parse_target(target)
        str = target.to_s
        reject_unknown_scheme(str)
        return Target.new(:unix, nil, nil, unix_path(str)) if str.start_with?('unix:')
        return xds_target(str) if str.start_with?('xds:')
        str = strip_scheme(str)
        host, port = split_host_port(str)
        Target.new(:tcp, host, port, nil)
      end

      # "xds:///my-service" names a resource, not a host to look up; the
      # authority-qualified form ("xds://authority/my-service") picks a
      # non-default management server, which is federation and out of
      # scope here, so it is rejected rather than silently mishandled.
      # Loads (and validates) the bootstrap immediately so a bad
      # GRPC_XDS_BOOTSTRAP fails channel construction, not the first RPC.
      def xds_target(str)
        rest = str.delete_prefix('xds:')
        rest = rest.delete_prefix('//') if rest.start_with?('//')
        if rest.include?('/') && !rest.start_with?('/')
          fail ArgumentError,
               "unsupported xds target #{str.inspect}: authority-qualified xds " \
               'targets (federation) are not supported'
        end
        name = rest.delete_prefix('/')
        fail ArgumentError, "bad xds target #{str.inspect}: missing resource name" if name.empty?
        load_xds!
        XdsClient.bootstrap!
        Target.new(:xds, name, nil, name)
      end

      # xds_client.rb loads the generated Envoy protobuf classes, which is
      # tens of thousands of objects that a dns: or unix: channel has no use
      # for. Nothing requires it until a target actually names the xds
      # scheme. require_relative is idempotent, so this costs one hash lookup
      # per call after the first.
      def load_xds!
        require_relative 'xds_client'
        true
      end

      # Resolves +target+'s host to every address it names -- A and AAAA
      # records alike, via the system resolver -- rather than just the one
      # a single lookup happens to return first, so an LB policy can hold a
      # subchannel per address instead of leaving that fan-out to whatever
      # Socket.tcp did internally. With grpc.dns_enable_srv_queries set,
      # SRV records take priority over the plain A/AAAA lookup; see
      # #srv_addresses. A :unix target has nothing to resolve; an :xds
      # target asks the shared XdsClient for the endpoints its resource
      # chain (LDS -> RDS -> CDS -> EDS) currently names.
      #
      # Mutates +target.addresses+ and also returns it.
      def resolve_addresses(target, args = {})
        target.addresses =
          case target.scheme
          when :unix then [target]
          when :xds then (load_xds! and XdsClient.instance.resolve_endpoints(target.path))
          else dns_addresses(target, args)
          end
      end

      def dns_addresses(target, args)
        if ChannelArgs.int(args, ChannelArgs::DNS_ENABLE_SRV_QUERIES, 0) != 0
          srv = srv_addresses(target)
          return srv unless srv.empty?
        end
        a_addresses(target, target.port)
      end

      def a_addresses(target, port)
        Addrinfo.getaddrinfo(target.host, port, nil, :STREAM)
                .map { |ai| Target.new(:tcp, ai.ip_address, port, nil) }
                .uniq(&:host)
      end

      # "_grpc_config._tcp.<host>" is the SRV name gRPC's DNS resolver
      # queries for (see A5, grpclb-in-dns); each record it returns names a
      # target host and port to resolve in turn, standing in for a plain
      # A/AAAA lookup on +target+ itself. Ordered by ascending priority
      # (lower tries first) and, within a priority, descending weight,
      # matching the preference gRPC's weighted-random selection encodes
      # without reproducing the randomness -- there is no separate LB
      # concept of SRV weight for a deterministic pure Ruby core to defer
      # to. Returns [] when the host has no SRV record, so the caller
      # falls back to a plain A/AAAA lookup exactly as gRPC's DNS resolver
      # does.
      def srv_addresses(target)
        records = Resolv::DNS.open do |dns|
          dns.getresources("_grpc_config._tcp.#{target.host}", Resolv::DNS::Resource::IN::SRV)
        end
        records.sort_by { |r| [r.priority, -r.weight] }
               .flat_map { |r| a_addresses(Target.new(:tcp, r.target.to_s, r.port, nil), r.port) }
      end

      # Reads the "grpc_config=" TXT record gRPC's DNS-based service
      # config publishing convention names (A2, service-configs-in-dns),
      # and returns the JSON payload following that prefix, or nil when
      # +target+ has no such record. Only a :tcp target has a DNS host to
      # query; :unix has no name server involved and :xds resolves its
      # config, if any, through the xDS control plane instead.
      def service_config_json(target)
        return nil unless target.scheme == :tcp
        records = Resolv::DNS.open { |dns| dns.getresources(target.host, Resolv::DNS::Resource::IN::TXT) }
        match = records.map(&:data).find { |text| text.start_with?('grpc_config=') }
        match&.delete_prefix('grpc_config=')
      end

      # "google-c2p:///service" (and any other scheme this implementation
      # does not resolve) used to parse as the host "google-c2p" on port 0,
      # so the channel was built and only failed later, connecting to a
      # name the caller never wrote. A scheme this implementation does not
      # resolve has to say so. Only the "scheme://" form is treated as a
      # scheme, because "localhost:50051" is a host and a port.
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
      # then grpc.http_proxy and grpc.address_http_proxy, then the
      # grpc_proxy/https_proxy/http_proxy environment variables, in that
      # order, and the no_grpc_proxy/no_proxy exclusion list. A channel
      # argument always beats the environment, matching gRPC's own
      # precedence for these two args. Returns nil, the common case, when no
      # proxy applies. Unix targets never proxy, mirroring C-core.
      def proxy_for(target, args)
        return nil if [:unix, :xds].include?(target.scheme)
        return nil if ChannelArgs.int(args, ChannelArgs::ENABLE_HTTP_PROXY, 1).zero?
        uri_str = configured_proxy_uri(args)
        return nil if uri_str.nil? || no_proxy?(target.host)
        parse_proxy_url(uri_str)
      end

      # A channel argument always beats the environment, and an empty value
      # counts as unset wherever it came from.
      def configured_proxy_uri(args)
        from_args = ChannelArgs.str(args, ChannelArgs::HTTP_PROXY) ||
                    ChannelArgs.str(args, ChannelArgs::ADDRESS_HTTP_PROXY)
        candidate = from_args ||
                    PROXY_ENV_VARS.map { |name| ENV[name] }.find { |v| v && !v.empty? }
        candidate unless candidate.nil? || candidate.empty?
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
      # Wildcard hosts grpc.expand_wildcard_addrs treats as needing
      # expansion into every concrete local address of that family, rather
      # than left as the one socket the kernel would otherwise route every
      # local address to on its own.
      WILDCARD_HOSTS = ['0.0.0.0', '::'].freeze

      # Binds a listening socket for +addr+ ("host:port"); port 0 picks one.
      # Normally one socket. grpc.expand_wildcard_addrs turns a wildcard
      # host into one socket per concrete local address of that family,
      # sharing the port the first one bound (or was given).
      #
      # @return [Array<Array(TCPServer, Integer)>] one [listener, port] pair
      #   per bound socket
      def listen(addr, so_reuseport: false, expand_wildcard_addrs: false)
        target = parse_target(addr)
        return [[UNIXServer.new(target.path), 0]] if target.scheme == :unix
        if expand_wildcard_addrs && WILDCARD_HOSTS.include?(target.host)
          return listen_expanded(target, so_reuseport)
        end
        [listen_one(target.host, target.port, so_reuseport)]
      end

      def listen_one(host, port, so_reuseport)
        server = TCPServer.new(host, port)
        server.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
        if so_reuseport && Socket.const_defined?(:SO_REUSEPORT)
          server.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEPORT, 1)
        end
        [server, server.addr[1]]
      end

      # Binds every concrete local address of +target.host+'s family instead
      # of the one wildcard socket, so the server reports (and, if a
      # firewall or NIC drops the wildcard route, actually accepts on) each
      # address individually. The first successful bind picks the port when
      # +target.port+ is 0; every other address reuses exactly that port.
      # An address present in the interface list but not actually bindable
      # (e.g. a VPN address with no local listening stack) is skipped rather
      # than failing the whole call, the way grpc_tcp_server_add_port does.
      # Every concrete address bound to a local interface of +family+, once
      # each. A link-local IPv6 address carries a "%scope" suffix that
      # TCPServer.new does not accept back as a host.
      def local_addresses(family)
        Socket.getifaddrs.each_with_object([]) do |ifaddr, hosts|
          addr = ifaddr.addr
          next if addr.nil? || addr.afamily != family
          ip = addr.ip_address.split('%').first
          hosts << ip unless hosts.include?(ip)
        end
      end

      def listen_expanded(target, so_reuseport)
        family = target.host.include?(':') ? Socket::AF_INET6 : Socket::AF_INET
        hosts = local_addresses(family)
        if hosts.empty?
          fail SocketError, "no local address found to expand #{target.host}"
        end
        port = target.port
        listeners = hosts.each_with_object([]) do |host, acc|
          begin
            entry = listen_one(host, port, so_reuseport)
          rescue SystemCallError
            next
          end
          port = entry.last
          acc << entry
        end
        if listeners.empty?
          fail SocketError, "could not bind any local address to expand #{target.host}"
        end
        listeners
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
