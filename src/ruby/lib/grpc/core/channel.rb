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

require_relative '../version'
require_relative 'call'
require_relative 'channel_args'
require_relative 'connection'
require_relative 'constants'
require_relative 'credentials'
require_relative 'transport'

module GRPC
  module Core
    # A client-side channel to one target. Replaces rb_channel.c.
    #
    # The transport is created lazily: the first RPC, or an explicit
    # connectivity_state(true), opens the socket. Connection loss moves the
    # channel back to IDLE so that the next RPC reconnects.
    class Channel
      SSL_TARGET = :'grpc.ssl_target_name_override'
      ENABLE_CENSUS = :'grpc.census'
      MAX_CONCURRENT_STREAMS = :'grpc.max_concurrent_streams'
      MAX_MESSAGE_LENGTH = :'grpc.max_receive_message_length'

      # Minimum gap between connection attempts, so a hard-down target cannot
      # spin the reconnect loop.
      RECONNECT_BACKOFF = 0.05

      # Every live channel, weakly held, so that GRPC.postfork_child can drop
      # the transports a child process inherited but cannot drive.
      LIVE = ObjectSpace::WeakMap.new

      # Discards the inherited transport of every channel in this process.
      # Only safe to call in a freshly forked child, where a single thread
      # runs and the inherited mutexes may be held by threads that are gone.
      def self.reset_all_after_fork!
        LIVE.each_key(&:reset_after_fork!)
        nil
      end

      attr_reader :target, :call_credentials

      def initialize(target, channel_args, credentials)
        @target = target
        @args = ChannelArgs.normalize(channel_args)
        @credentials = resolve_credentials(credentials)
        @parsed_target = Transport.parse_target(target)
        @max_receive_message_length = ChannelArgs.int(
          @args, ChannelArgs::MAX_RECEIVE_MESSAGE_LENGTH,
          ChannelArgs::DEFAULT_MAX_RECEIVE_MESSAGE_LENGTH)
        @mu = Mutex.new
        @cv = ConditionVariable.new
        @state = ConnectivityStates::IDLE
        @connection = nil
        @connect_thread = nil
        @last_attempt = nil
        @last_error = nil
        @destroyed = false
        LIVE[self] = true
      end

      def initialize_copy(_other)
        fail TypeError,
             'Copy initialization of GRPC::Core::Channel is not supported'
      end

      def secure?
        !@credentials.nil?
      end

      def scheme
        secure? ? 'https' : 'http'
      end

      def authority
        @authority ||=
          ChannelArgs.str(@args, ChannelArgs::DEFAULT_AUTHORITY) ||
          ssl_target_override ||
          default_authority
      end

      def user_agent
        @user_agent ||= begin
          parts = [ChannelArgs.str(@args, ChannelArgs::PRIMARY_USER_AGENT)]
          parts << "grpc-ruby-core/#{GRPC::VERSION} (#{RUBY_ENGINE}-" \
                   "#{RUBY_VERSION}; kantan)"
          parts << ChannelArgs.str(@args, ChannelArgs::SECONDARY_USER_AGENT)
          parts.compact.reject(&:empty?).join(' ')
        end
      end

      # rubocop:disable Style/OptionalBooleanParameter -- C API signature
      def connectivity_state(try_to_connect = false)
        fail 'closed!' if @destroyed
        @mu.synchronize do
          maybe_start_connect_locked if try_to_connect && connectable_locked?
          @state
        end
      end
      # rubocop:enable Style/OptionalBooleanParameter

      # Blocks until the state differs from +last_state+ or +deadline+ passes.
      #
      # @return [Boolean] true when the state changed in time
      def watch_connectivity_state(last_state, deadline)
        fail 'closed!' if @destroyed
        unless last_state.is_a?(Integer)
          fail TypeError,
               'bad type for last_state. want a GRPC::Core::ChannelState constant'
        end
        limit = monotonic_from(deadline)
        @mu.synchronize do
          loop do
            return true if @state != last_state
            remaining = limit - RpcStream.now
            return false if remaining <= 0
            @cv.wait(@mu, remaining)
          end
        end
      end

      def create_call(parent, mask, method, host, deadline)
        fail 'closed!' if @destroyed
        Call.client(channel: self, method: method, host: host,
                    deadline: deadline, parent: parent, mask: mask)
      end

      def destroy
        connection = nil
        @mu.synchronize do
          return nil if @destroyed
          @destroyed = true
          connection = @connection
          @connection = nil
          @state = ConnectivityStates::FATAL_FAILURE
          @cv.broadcast
        end
        connection&.close
        nil
      end
      alias close destroy

      # Opens a stream for a new RPC, connecting first if necessary.
      #
      # @api private
      def open_stream(deadline: nil)
        connection = await_connection(deadline)
        connection.open_rpc
      end

      # Drops the transport this channel inherited across a fork so that the
      # next RPC dials again. The synchronisation primitives are replaced
      # rather than taken, because a lock held at fork time is never released.
      #
      # @api private
      def reset_after_fork!
        connection = @connection
        @mu = Mutex.new
        @cv = ConditionVariable.new
        @connection = nil
        @connect_thread = nil
        @idle_timer = nil
        @last_attempt = nil
        @last_error = nil
        @state = ConnectivityStates::IDLE unless @destroyed
        connection&.abandon
        nil
      end

      private

      def resolve_credentials(credentials)
        case credentials
        when Symbol
          unless credentials == :this_channel_is_insecure
            fail TypeError, 'bad creds symbol, want :this_channel_is_insecure'
          end
          nil
        when XdsChannelCredentials, ChannelCredentials
          @call_credentials = credentials.call_credentials
          credentials
        else
          fail TypeError,
               'bad creds, want ChannelCredentials or XdsChannelCredentials'
        end
      end

      def ssl_target_override
        ChannelArgs.str(@args, ChannelArgs::SSL_TARGET_NAME_OVERRIDE)
      end

      def default_authority
        return @parsed_target.path.to_s if @parsed_target.scheme == :unix
        "#{@parsed_target.host}:#{@parsed_target.port}"
      end

      def monotonic_from(deadline)
        seconds = TimeSpec.from(deadline).to_relative_seconds
        return RpcStream.now + (365 * 24 * 3600) if seconds.nil?
        RpcStream.now + seconds
      end

      # An IDLE channel connects immediately, as C-core does. The backoff only
      # throttles retries after a failure.
      def connectable_locked?
        return false if @connection&.alive?
        case @state
        when ConnectivityStates::IDLE
          true
        when ConnectivityStates::TRANSIENT_FAILURE
          @last_attempt.nil? ||
            (RpcStream.now - @last_attempt) >= RECONNECT_BACKOFF
        else
          false
        end
      end

      def maybe_start_connect_locked
        return if @connect_thread
        @last_attempt = RpcStream.now
        transition_locked(ConnectivityStates::CONNECTING)
        @connect_thread = Thread.new { connect_worker }
        @connect_thread.name = 'grpc-connect'
      end

      def connect_worker
        connection = build_connection
        @mu.synchronize do
          @connect_thread = nil
          if @destroyed
            connection.close
          else
            @connection = connection
            @last_error = nil
            transition_locked(ConnectivityStates::READY)
          end
        end
      rescue StandardError => e
        @mu.synchronize do
          @connect_thread = nil
          @last_error = e
          transition_locked(ConnectivityStates::TRANSIENT_FAILURE)
          schedule_idle_locked
        end
      end

      # Returns to IDLE once the backoff expires, so that watchers wake up and
      # the next attempt is allowed.
      def schedule_idle_locked
        return if @idle_timer
        @idle_timer = Thread.new do
          sleep RECONNECT_BACKOFF
          @mu.synchronize do
            @idle_timer = nil
            next if @destroyed
            next unless @state == ConnectivityStates::TRANSIENT_FAILURE
            transition_locked(ConnectivityStates::IDLE)
          end
        end
      end

      def build_connection
        socket, peer, peer_cert = Transport.connect(
          @parsed_target, @credentials, ssl_target_override)
        connection = Connection.new(
          socket, peer: peer, client: true, peer_cert: peer_cert,
                  max_receive_message_length: @max_receive_message_length,
                  on_close: method(:on_connection_closed))
        connection.start
        # A completed TCP connect is not a usable channel: the peer may have
        # queued the socket and never serviced it. READY means the HTTP/2
        # handshake finished.
        begin
          connection.await_handshake(Transport::DEFAULT_CONNECT_TIMEOUT)
        rescue StandardError => e
          connection.close
          raise e
        end
        connection
      end

      def on_connection_closed(connection)
        @mu.synchronize do
          next unless @connection.equal?(connection)
          @connection = nil
          transition_locked(ConnectivityStates::IDLE) unless @destroyed
        end
      end

      def transition_locked(state)
        return if @state == state
        @state = state
        @cv.broadcast
      end

      # Blocks until a live connection exists, raising the connect error when
      # the attempt fails so that Call can turn it into an UNAVAILABLE status.
      def await_connection(deadline)
        limit = deadline || (RpcStream.now + Transport::DEFAULT_CONNECT_TIMEOUT)
        @mu.synchronize do
          loop do
            fail Connection::Closed, 'channel closed' if @destroyed
            return @connection if @connection&.alive?
            if @state == ConnectivityStates::TRANSIENT_FAILURE && @last_error
              error = @last_error
              @last_error = nil
              raise error
            end
            maybe_start_connect_locked if connectable_locked?
            remaining = limit - RpcStream.now
            if remaining <= 0
              fail Connection::Closed, "connect timed out to #{@target}"
            end
            @cv.wait(@mu, remaining)
          end
        end
      end
    end
  end
end
