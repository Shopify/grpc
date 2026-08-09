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

module GRPC
  module Core
    # ChannelCredentials holds the PEM-encoded SSL materials used to secure a
    # client channel.  This is a pure-Ruby replacement for the C extension class.
    class ChannelCredentials
      attr_reader :pem_root_certs, :pem_private_key, :pem_cert_chain

      def initialize(pem_root_certs = nil, pem_private_key = nil, pem_cert_chain = nil)
        validate_pem_arg!(pem_root_certs, 'pem_root_certs')
        validate_pem_arg!(pem_private_key, 'pem_private_key')
        validate_pem_arg!(pem_cert_chain, 'pem_cert_chain')

        # Supplying exactly one of the key/cert pair is an error.
        if pem_private_key.nil? && !pem_cert_chain.nil?
          fail TypeError, 'could not create a credentials because pem_private_key is nil'
        end
        if pem_cert_chain.nil? && !pem_private_key.nil?
          fail TypeError, 'could not create a credentials because pem_cert_chain is nil'
        end

        @pem_root_certs = pem_root_certs
        @pem_private_key = pem_private_key
        @pem_cert_chain = pem_cert_chain
      end

      # Returns nil so that a plain ChannelCredentials and a CompositeChannelCredentials
      # can be treated uniformly by the transport layer.
      def call_credentials
        nil
      end

      def ssl?
        true
      end

      # Composes per-call credentials with this channel credential.
      # Returns +self+ when given no arguments; otherwise every argument
      # (after +flatten+) must be a {CallCredentials}, else +TypeError+.
      # Returns a {CompositeChannelCredentials}.
      def compose(*others)
        return self if others.empty?

        flat_others = others.flatten
        flat_others.each do |o|
          fail TypeError, "Argument to compose must be a CallCredentials, got #{o.class}" \
            unless o.is_a?(CallCredentials)
        end

        call_creds = flat_others.size == 1 ? flat_others.first : CompositeCallCredentials.new(flat_others)
        CompositeChannelCredentials.new(self, call_creds)
      end

      # Stores the PEM bundle that overrides the system default SSL roots.
      # Called by <tt>src/ruby/lib/grpc.rb</tt> at load time.
      # rubocop:disable Naming/AccessorMethodName -- name fixed by the C API
      def self.set_default_roots_pem(pem_string)
        @default_roots_pem = pem_string
      end
      # rubocop:enable Naming/AccessorMethodName

      # Returns the PEM bundle previously set via {set_default_roots_pem}.
      class << self
        attr_reader :default_roots_pem
      end

      private

      def validate_pem_arg!(arg, name)
        return if arg.nil? || arg.is_a?(String)

        fail TypeError, "Argument #{name} must be nil or a String, got #{arg.class}"
      end
    end

    # CompositeChannelCredentials pairs a ChannelCredentials with one or more
    # CallCredentials.  It subclasses ChannelCredentials so that +is_a?+
    # checks in the transport layer remain true.
    class CompositeChannelCredentials < ChannelCredentials
      attr_reader :channel_credentials, :call_credentials

      def initialize(channel_creds, call_creds)
        super()
        @channel_credentials = channel_creds
        @call_credentials = call_creds
      end

      def pem_root_certs
        @channel_credentials.pem_root_certs
      end

      def pem_private_key
        @channel_credentials.pem_private_key
      end

      def pem_cert_chain
        @channel_credentials.pem_cert_chain
      end

      # Returns a new CompositeChannelCredentials whose call credentials are
      # the existing ones composed with the new ones.
      def compose(*others)
        return self if others.empty?

        flat_others = others.flatten
        flat_others.each do |o|
          fail TypeError, "Argument to compose must be a CallCredentials, got #{o.class}" \
            unless o.is_a?(CallCredentials)
        end

        if @call_credentials
          CompositeChannelCredentials.new(@channel_credentials, @call_credentials.compose(*flat_others))
        else
          CompositeChannelCredentials.new(@channel_credentials, CompositeCallCredentials.new(flat_others))
        end
      end
    end

    # XdsChannelCredentials wraps a fallback ChannelCredentials and uses xDS
    # to negotiate security.  It deliberately does NOT subclass
    # ChannelCredentials so that the transport can distinguish the two types.
    class XdsChannelCredentials
      attr_reader :fallback_credentials

      def initialize(fallback_creds)
        fail TypeError, 'expected grpc_channel_credentials' unless fallback_creds.is_a?(ChannelCredentials)

        @fallback_credentials = fallback_creds
      end

      def pem_root_certs
        @fallback_credentials.pem_root_certs
      end

      def pem_private_key
        @fallback_credentials.pem_private_key
      end

      def pem_cert_chain
        @fallback_credentials.pem_cert_chain
      end

      def call_credentials
        @fallback_credentials.call_credentials
      end

      def ssl?
        true
      end

      def compose(*others)
        return self if others.empty?

        flat_others = others.flatten
        flat_others.each do |o|
          fail TypeError, "Argument to compose must be a CallCredentials, got #{o.class}" \
            unless o.is_a?(CallCredentials)
        end

        call_creds = flat_others.size == 1 ? flat_others.first : CompositeCallCredentials.new(flat_others)
        CompositeChannelCredentials.new(self, call_creds)
      end
    end

    # ServerCredentials holds the PEM-encoded SSL materials used to secure a
    # server.  This is a pure-Ruby replacement for the C extension class.
    class ServerCredentials
      attr_reader :pem_root_certs, :pem_key_certs

      # grpc_ssl_client_certificate_request_type enum values
      # (from include/grpc/grpc_security_constants.h)
      GRPC_SSL_DONT_REQUEST_CLIENT_CERTIFICATE = 0
      GRPC_SSL_REQUEST_CLIENT_CERTIFICATE_BUT_DONT_VERIFY = 1
      GRPC_SSL_REQUEST_CLIENT_CERTIFICATE_AND_VERIFY = 2
      GRPC_SSL_REQUEST_AND_REQUIRE_CLIENT_CERTIFICATE_BUT_DONT_VERIFY = 3
      GRPC_SSL_REQUEST_AND_REQUIRE_CLIENT_CERTIFICATE_AND_VERIFY = 4

      # rubocop:disable Style/OptionalBooleanParameter -- C API signature
      def initialize(pem_root_certs, pem_key_certs, force_client_auth = false)
        validate_root_certs!(pem_root_certs)
        validate_key_certs!(pem_key_certs)
        @client_certificate_request = resolve_client_certificate_request(force_client_auth)

        @pem_root_certs = pem_root_certs
        @pem_key_certs = pem_key_certs
      end
      # rubocop:enable Style/OptionalBooleanParameter

      # Returns the resolved grpc_ssl_client_certificate_request_type enum
      # integer.
      attr_reader :client_certificate_request

      # Returns true when the server requires a client certificate.
      def force_client_auth?
        @client_certificate_request >= GRPC_SSL_REQUEST_AND_REQUIRE_CLIENT_CERTIFICATE_BUT_DONT_VERIFY
      end

      private

      def validate_root_certs!(arg)
        return if arg.nil? || arg.is_a?(String)

        fail TypeError, "Argument pem_root_certs must be nil or a String, got #{arg.class}"
      end

      def validate_key_certs!(pem_key_certs)
        unless pem_key_certs.is_a?(Array)
          fail TypeError, "bad pem_key_certs: got:<#{pem_key_certs&.class || 'nil'}> want: <Array>"
        end
        if pem_key_certs.empty?
          fail TypeError, 'bad pem_key_certs: it had no elements'
        end
        pem_key_certs.each { |key_cert| validate_key_cert_pair!(key_cert) }
      end

      def validate_key_cert_pair!(key_cert)
        unless key_cert.is_a?(Hash)
          fail TypeError, "could not create a server credential: want <Hash>, got <#{key_cert.class}>"
        end
        if key_cert[:private_key].nil?
          fail TypeError, 'could not create a server credential: want nil private key'
        end
        return unless key_cert[:cert_chain].nil?
        fail TypeError, 'could not create a server credential: want nil cert chain'
      end

      def resolve_client_certificate_request(force_client_auth)
        case force_client_auth
        when true
          GRPC_SSL_REQUEST_AND_REQUIRE_CLIENT_CERTIFICATE_AND_VERIFY
        when false
          GRPC_SSL_DONT_REQUEST_CLIENT_CERTIFICATE
        when Integer
          force_client_auth
        else
          fail TypeError,
               "bad force_client_auth: got:<#{force_client_auth.class}> want: <True|False|Integer>"
        end
      end
    end

    # XdsServerCredentials wraps a fallback ServerCredentials and uses xDS
    # to negotiate security.
    class XdsServerCredentials
      attr_reader :fallback_credentials

      def initialize(fallback_creds)
        fail TypeError, 'expected grpc_server_credentials' unless fallback_creds.is_a?(ServerCredentials)

        @fallback_credentials = fallback_creds
      end

      def pem_root_certs
        @fallback_credentials.pem_root_certs
      end

      def pem_key_certs
        @fallback_credentials.pem_key_certs
      end

      def client_certificate_request
        @fallback_credentials.client_certificate_request
      end

      def force_client_auth?
        @fallback_credentials.force_client_auth?
      end
    end
  end
end
