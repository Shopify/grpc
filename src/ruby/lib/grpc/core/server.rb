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

require_relative 'call'
require_relative 'channel_args'
require_relative 'connection'
require_relative 'constants'
require_relative 'credentials'
require_relative 'metadata'
require_relative 'transport'

module GRPC
  module Core
    # A gRPC server. Replaces rb_server.c.
    #
    # Ports are bound by #add_http2_port and only accepted on after #start.
    # Each accepted socket becomes a Connection whose new RPCs are queued for
    # #request_call.
    class Server
      # Headers the transport consumes rather than surfacing as metadata.
      RESERVED_HEADERS = %w[
        te content-type grpc-timeout grpc-encoding grpc-accept-encoding
        grpc-internal-encoding-request
      ].freeze

      TIMEOUT_UNITS = {
        'n' => 1e-9, 'u' => 1e-6, 'm' => 1e-3, 'S' => 1.0, 'M' => 60.0,
        'H' => 3600.0
      }.freeze

      # How often shutdown re-checks whether the last RPC has finished.
      DRAIN_POLL_INTERVAL = 0.005

      def initialize(channel_args)
        @args = ChannelArgs.normalize(channel_args)
        @max_receive_message_length = ChannelArgs.int(
          @args, ChannelArgs::MAX_RECEIVE_MESSAGE_LENGTH,
          ChannelArgs::DEFAULT_MAX_RECEIVE_MESSAGE_LENGTH)
        @max_concurrent_streams = ChannelArgs.int(
          @args, ChannelArgs::MAX_CONCURRENT_STREAMS, 100)
        @so_reuseport = !ChannelArgs.int(@args, ChannelArgs::SO_REUSEPORT, 1).zero?
        @mu = Mutex.new
        @cv = ConditionVariable.new
        @listeners = []
        @connections = []
        @pending = []
        @acceptors = []
        @running = false
        @shutdown = false
        @destroyed = false
      end

      def initialize_copy(_other)
        fail TypeError,
             'Copy initialization of GRPC::Core::Server is not supported'
      end

      # Binds +addr+ and returns the port that was actually bound.
      def add_http2_port(addr, credentials)
        fail 'destroyed!' if @destroyed || @shutdown
        server_creds = resolve_credentials(credentials)
        listener, port = Transport.listen(addr, so_reuseport: @so_reuseport)
        @mu.synchronize { @listeners << [listener, server_creds] }
        port
      rescue SystemCallError => e
        fail "could not add port #{addr} to server, not sure why: #{e.message}"
      end

      def start
        fail 'destroyed!' if @destroyed || @shutdown
        @mu.synchronize do
          return nil if @running
          @running = true
          @listeners.each do |listener, creds|
            @acceptors << Thread.new { accept_loop(listener, creds) }
          end
        end
        nil
      end

      # Blocks until the next RPC arrives.
      #
      # @return [Struct::NewServerRpc]
      def request_call
        fail 'destroyed!' if @destroyed
        @mu.synchronize do
          loop do
            fail CallError, 'request_call completion failed' if @shutdown
            break @pending.shift unless @pending.empty?
            @cv.wait(@mu)
          end
        end
      end

      # Stops accepting, then waits up to +timeout+ for live RPCs to finish
      # before cancelling them.
      def shutdown_and_notify(timeout)
        listeners = nil
        @mu.synchronize do
          return nil if @shutdown
          @shutdown = true
          listeners = @listeners.dup
          @listeners.clear
          @cv.broadcast
        end
        listeners.each { |entry| close_listener(entry.first) }
        @acceptors.each { |t| t.join(1) }
        drain(timeout)
        nil
      end

      def destroy
        connections = nil
        @mu.synchronize do
          return nil if @destroyed
          @destroyed = true
          @shutdown = true
          connections = @connections.dup
          @connections.clear
          @listeners.each { |entry| close_listener(entry.first) }
          @listeners.clear
          @cv.broadcast
        end
        connections.each { |c| c.close(StatusCodes::UNAVAILABLE, 'Server shutdown') }
        nil
      end
      alias close destroy

      private

      def resolve_credentials(credentials)
        case credentials
        when Symbol
          unless credentials == :this_port_is_insecure
            fail TypeError, 'bad creds symbol, want :this_port_is_insecure'
          end
          nil
        when XdsServerCredentials, ServerCredentials
          credentials
        else
          fail TypeError,
               'failed to create server because credentials parameter has an ' \
               'invalid type, want ServerCredentials or XdsServerCredentials'
        end
      end

      # Closing a listening socket does not reliably reset the connections the
      # kernel already completed into its backlog, so a client whose socket was
      # never accepted would keep believing its transport is healthy. Hand each
      # queued socket an explicit close first.
      def close_listener(listener)
        loop do
          socket = listener.accept_nonblock(exception: false)
          break if socket.nil? || socket == :wait_readable
          begin
            socket.close
          rescue IOError, SystemCallError
            nil
          end
        end
        listener.close
      rescue IOError, SystemCallError
        nil
      end

      def accept_loop(listener, credentials)
        loop do
          socket = listener.accept
          # The client end sets this in Transport.open_socket; the accepted end
          # needs it just as much. A reply is a large DATA write followed by a
          # small trailing HEADERS frame, and with Nagle enabled that trailer
          # waits for an acknowledgement of the data before it goes out. The
          # caller cannot finish the RPC until the trailer arrives.
          begin
            socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
          rescue IOError, SystemCallError
            nil # a Unix socket, or one that died between accept and here
          end
          Thread.new { serve(socket, credentials) }
        end
      rescue IOError, SystemCallError
        nil
      end

      def serve(socket, credentials)
        socket = tls_wrap(socket, credentials) if credentials
        peer = Transport.peer_of(socket)
        peer_cert = socket.respond_to?(:peer_cert) ? socket.peer_cert&.to_pem : nil
        connection = Connection.new(
          socket, peer: peer, client: false, peer_cert: peer_cert,
                  max_receive_message_length: @max_receive_message_length,
                  max_concurrent_streams: @max_concurrent_streams,
                  on_new_rpc: method(:enqueue_rpc),
                  on_close: method(:forget_connection))
        # A socket accepted just as the server shuts down is dropped without
        # ever starting a session; Connection#close closes the socket itself
        # in that case.
        return connection.close unless register(connection)
        connection.start
      rescue StandardError
        begin
          socket.close
        rescue StandardError
          nil
        end
      end

      def tls_wrap(socket, credentials)
        context = Transport.server_ssl_context(credentials)
        ssl = OpenSSL::SSL::SSLSocket.new(socket, context)
        ssl.sync_close = true
        ssl.accept
        ssl
      end

      def register(connection)
        @mu.synchronize do
          return false if @shutdown || @destroyed
          @connections << connection
          true
        end
      end

      def forget_connection(connection)
        @mu.synchronize do
          @connections.delete(connection)
          @cv.broadcast
        end
      end

      # Runs on a connection reader thread; only queues work.
      def enqueue_rpc(stream, headers)
        method_path = header(headers, ':path')
        return if method_path.nil?
        deadline = deadline_from(header(headers, 'grpc-timeout'))
        stream.send_encoding = 'identity'
        call = Call.server(stream: stream, headers: headers,
                           deadline: deadline, server: self)
        rpc = Struct::NewServerRpc.new(
          method_path, header(headers, ':authority'), deadline,
          public_metadata(headers), call)
        @mu.synchronize do
          if @shutdown || @destroyed
            stream.reset(7) # REFUSED_STREAM
          else
            @pending << rpc
            @cv.broadcast
          end
        end
      end

      def header(headers, name)
        headers.find { |n, _| n == name }&.last
      end

      def public_metadata(headers)
        Metadata.decode(headers.reject { |n, _| RESERVED_HEADERS.include?(n) })
      end

      def deadline_from(timeout)
        return Time.at(TimeSpec::INF_FUTURE_TIME_SEC) if timeout.nil?
        match = /\A(\d+)([numSMH])\z/.match(timeout)
        return Time.at(TimeSpec::INF_FUTURE_TIME_SEC) if match.nil?
        Time.now + (match[1].to_i * TIMEOUT_UNITS.fetch(match[2]))
      end

      # Waits for outstanding RPCs to finish, then drops the connections.
      #
      # Streams complete on connection reader threads, which do not signal the
      # server, so this polls rather than waiting on a condition variable that
      # would only be woken when a whole connection goes away.
      def drain(timeout)
        limit = drain_limit(timeout)
        sleep DRAIN_POLL_INTERVAL until idle? || RpcStream.now >= limit
        connections = @mu.synchronize do
          live = @connections.dup
          @connections.clear
          live
        end
        connections.each do |c|
          c.close(StatusCodes::UNAVAILABLE, 'Server shutdown')
        end
      end

      def idle?
        @mu.synchronize { @connections.all? { |c| c.active_rpcs.zero? } }
      end

      def drain_limit(timeout)
        return RpcStream.now + 30 if timeout.nil?
        seconds = TimeSpec.from(timeout).to_relative_seconds
        seconds.nil? ? RpcStream.now + 30 : RpcStream.now + seconds
      end
    end
  end
end
