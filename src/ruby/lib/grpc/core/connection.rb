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

require_relative 'http2/kantan'
require_relative 'rpc_stream'
require_relative 'status_codes'

module GRPC
  module Core
    # Binds one HTTP/2 session to the RPCs running over it.
    #
    # Every callback below runs on the session's reader thread, so they only
    # ever append to per-stream buffers and signal; the RPC threads do the
    # blocking.
    #
    # @api private
    class Connection < Http2::Kantan::Handler
      # HTTP/2 error code to gRPC status code, per the gRPC HTTP/2 spec.
      HTTP2_ERROR_TO_STATUS = {
        0 => StatusCodes::INTERNAL,
        1 => StatusCodes::INTERNAL,
        2 => StatusCodes::INTERNAL,
        3 => StatusCodes::INTERNAL,
        4 => StatusCodes::INTERNAL,
        5 => StatusCodes::INTERNAL,
        6 => StatusCodes::INTERNAL,
        7 => StatusCodes::UNAVAILABLE,
        8 => StatusCodes::CANCELLED,
        9 => StatusCodes::INTERNAL,
        10 => StatusCodes::INTERNAL,
        11 => StatusCodes::RESOURCE_EXHAUSTED,
        12 => StatusCodes::PERMISSION_DENIED,
        13 => StatusCodes::UNKNOWN
      }.freeze

      attr_reader :session, :peer, :peer_cert

      # rubocop:disable Metrics/ParameterLists -- all but +io+ are keywords
      def initialize(io, peer:, client:, max_receive_message_length:,
                     max_concurrent_streams: 100, peer_cert: nil,
                     on_new_rpc: nil, on_close: nil)
        super()
        @io = io
        @peer = peer
        @peer_cert = peer_cert
        @client = client
        @max_receive_message_length = max_receive_message_length
        @on_new_rpc = on_new_rpc
        @on_close = on_close
        @streams = {}
        @mu = Mutex.new
        @closed = false
        @started = false
        @handshaked = false
        @handshake_cv = ConditionVariable.new
        @session = Http2::Kantan::H2::Session.new(
          io, handler: self, max_concurrent_streams: max_concurrent_streams)
      end
      # rubocop:enable Metrics/ParameterLists

      def client?
        @client
      end

      def start
        @mu.synchronize { @started = true }
        @client ? @session.connect : @session.receive
        self
      end

      # Blocks until the peer's first SETTINGS frame arrives, which is the
      # point at which the connection can actually carry an RPC. A socket the
      # peer accepted into its backlog but never serviced never gets here.
      def await_handshake(timeout)
        deadline = RpcStream.now + timeout
        @mu.synchronize do
          until @handshaked || @closed
            remaining = deadline - RpcStream.now
            break if remaining <= 0
            @handshake_cv.wait(@mu, remaining)
          end
          fail Closed, 'peer never completed the HTTP/2 handshake' unless @handshaked
        end
        self
      end

      def on_settings(_settings)
        @mu.synchronize do
          @handshaked = true
          @handshake_cv.broadcast
        end
      end

      def alive?
        @mu.synchronize { !@closed }
      end

      def active_rpcs
        @mu.synchronize { @streams.size }
      end

      # Client side: allocates the next stream. The HEADERS frame is written by
      # the caller through the returned RpcStream.
      def open_rpc
        @mu.synchronize do
          fail Closed, 'connection is closed' if @closed
          id = @session.new_stream
          @streams[id] = new_stream(id)
        end
      end

      def forget(stream_id)
        @mu.synchronize { @streams.delete(stream_id) }
      end

      # Sends GOAWAY and tears the socket down, failing every live RPC.
      def close(status = StatusCodes::UNAVAILABLE, details = 'Transport closed')
        started = @mu.synchronize do
          return if @closed
          @closed = true
          @started
        end
        if started
          # The session's write thread drains the queue and closes the socket.
          @session.shutdown
        else
          # No session threads exist yet, so nothing would ever drain a
          # shutdown command; drop the socket directly instead of leaking it.
          begin
            @io.close
          rescue StandardError
            nil
          end
        end
        fail_all(status, details)
        nil
      end

      # Drops a connection inherited across a fork. The child has the socket
      # but none of the session threads, so nothing can be negotiated on it;
      # the mutex is replaced too because the thread that held it is gone.
      def abandon
        @mu = Mutex.new
        @closed = true
        @streams = {}
        begin
          # Close the descriptor, not the TLS session: the parent still holds
          # the same socket, and SSLSocket#close would push a close_notify
          # alert down it and break the parent's connection.
          (@io.respond_to?(:io) ? @io.io : @io).close
        rescue StandardError
          nil
        end
        nil
      end

      def join
        @session.join
      end

      # ---- session callbacks ------------------------------------------------

      def on_headers(kstream)
        stream = @mu.synchronize { @streams[kstream.id] }
        if stream.nil?
          return if @client
          stream = accept(kstream)
          return if stream.nil?
        end
        stream.push_headers(kstream.headers)
      end

      def on_data(kstream, chunk)
        stream = @mu.synchronize { @streams[kstream.id] }
        stream&.push_data(chunk)
      end

      def on_trailers(kstream, headers)
        stream = @mu.synchronize { @streams[kstream.id] }
        stream&.push_trailers(headers)
      end

      def on_request(kstream)
        stream = @mu.synchronize { @streams[kstream.id] }
        stream&.push_eos
      end

      def on_stream_error(kstream, error_code)
        stream = @mu.synchronize { @streams.delete(kstream.id) }
        return if stream.nil?
        code = HTTP2_ERROR_TO_STATUS.fetch(error_code, StatusCodes::INTERNAL)
        stream.push_failure(code, "Stream reset by peer (#{error_code})")
      end

      def on_close
        @mu.synchronize { @closed = true }
        fail_all(StatusCodes::UNAVAILABLE, 'Transport closed')
        # The owner's callback is idempotent, so it is safe to run even when
        # close() already marked this connection dead.
        @on_close&.call(self)
      end

      # Raised when an RPC is started on a connection that has gone away.
      class Closed < StandardError; end

      private

      def new_stream(id)
        stream = RpcStream.new(
          self, id, max_receive_message_length: @max_receive_message_length)
        stream.peer = @peer
        stream.peer_cert = @peer_cert
        stream
      end

      # Server side: a HEADERS block on an unknown stream starts a new RPC.
      def accept(kstream)
        stream = @mu.synchronize do
          return nil if @closed
          @streams[kstream.id] = new_stream(kstream.id)
        end
        @on_new_rpc&.call(stream, kstream.headers)
        stream
      end

      def fail_all(code, details)
        streams = @mu.synchronize do
          live = @streams.values
          @streams.clear
          live
        end
        streams.each { |s| s.push_failure(code, details) }
      end
    end
  end
end
