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

require_relative 'status_codes'
require_relative 'message_compression'

module GRPC
  module Core
    # The transport-level state of one RPC, layered over a single HTTP/2
    # stream.
    #
    # Frames arrive on the connection's reader thread and are pushed in here,
    # which only appends to buffers and signals. Application threads block in
    # the +await_*+ and +read_message+ methods until their data arrives, the
    # deadline passes, or the stream fails.
    #
    # @api private
    class RpcStream
      # gRPC length-prefixed message header: one compression flag byte plus a
      # four byte big-endian length.
      FRAME_HEADER_SIZE = 5

      # How many bytes may sit between #send_message and the socket before the
      # caller is made to wait.
      WRITE_HIGH_WATER = 256 * 1024

      # A transport failure translated into a gRPC status.
      Failure = Struct.new(:code, :details)

      attr_reader :id, :connection
      attr_accessor :peer, :peer_cert, :recv_encoding, :send_encoding

      def initialize(connection, id, max_receive_message_length:)
        @connection = connection
        @id = id
        @max_receive_message_length = max_receive_message_length
        @mu = Mutex.new
        @cv = ConditionVariable.new
        @headers = nil
        @trailers = nil
        @buffer = +''.b
        @eos = false
        @failure = nil
        @local_closed = false
        @recv_encoding = 'identity'
        @send_encoding = 'identity'
        @write_mu = Mutex.new
        @write_cv = ConditionVariable.new
        @queued_bytes = 0
      end

      # ---- inbound, called from the connection reader thread ---------------

      def push_headers(pairs)
        @mu.synchronize do
          @headers = pairs
          @recv_encoding = header_value(pairs, 'grpc-encoding') || 'identity'
          @cv.broadcast
        end
      end

      def push_data(chunk)
        @mu.synchronize do
          @buffer << chunk
          @cv.broadcast
        end
      end

      def push_trailers(pairs)
        @mu.synchronize do
          @trailers = pairs
          @cv.broadcast
        end
      end

      def push_eos
        @mu.synchronize do
          @eos = true
          @trailers ||= @headers if @headers && trailers_only?(@headers)
          @cv.broadcast
        end
      end

      def push_failure(code, details)
        @mu.synchronize do
          @failure ||= Failure.new(code, details)
          @eos = true
          @cv.broadcast
        end
      end

      def failure
        @mu.synchronize { @failure }
      end

      # ---- inbound, called from application threads ------------------------

      # Blocks for the initial HEADERS block. Returns the header pairs, or nil
      # when the peer closed the stream without sending any.
      def await_headers(deadline)
        @mu.synchronize do
          wait_until(deadline) { @headers || @eos || @failure }
          @headers
        end
      end

      # Blocks for the trailing HEADERS block. Returns the header pairs, or an
      # empty list when the stream ended without trailers.
      def await_trailers(deadline)
        @mu.synchronize do
          wait_until(deadline) { @trailers || @eos || @failure }
          @trailers || []
        end
      end

      # True once the peer has half-closed its side of the stream.
      def remote_closed?
        @mu.synchronize { @eos }
      end

      # Blocks for one complete gRPC message. Returns nil at end of stream.
      def read_message(deadline)
        header = read_bytes(FRAME_HEADER_SIZE, deadline)
        return nil if header.nil?
        compressed = header.getbyte(0) == 1
        length = header.byteslice(1, 4).unpack1('N')
        if @max_receive_message_length.positive? &&
           length > @max_receive_message_length
          fail ResourceExhausted,
               "Received message larger than max (#{length} vs. " \
               "#{@max_receive_message_length})"
        end
        body = length.zero? ? +''.b : read_bytes(length, deadline)
        fail Truncated, 'truncated gRPC message' if body.nil?
        compressed ? MessageCompression.decompress(@recv_encoding, body) : body
      end

      # ---- outbound ---------------------------------------------------------

      def send_headers(pairs, end_stream: false)
        @local_closed ||= end_stream
        @connection.session.send_headers(@id, pairs, has_body: !end_stream)
      end

      # Frames and writes one message.
      #
      # Backpressure is applied at a watermark rather than after every
      # message: waiting for each frame to reach the socket costs a thread
      # handoff per message and collapses streaming throughput, while an
      # unbounded queue would let a slow peer exhaust memory.
      def send_message(payload, no_compress: false)
        body = payload.b
        flag = 0
        if !no_compress && @send_encoding != 'identity'
          body = MessageCompression.compress(@send_encoding, body)
          flag = 1
        end
        frame = [flag, body.bytesize].pack('CN') << body
        queue_write(frame)
        nil
      end

      def send_trailers(pairs)
        @local_closed = true
        @connection.session.send_trailers(@id, pairs)
      end

      def close_send
        return if @local_closed
        @local_closed = true
        @connection.session.send_data(@id, ''.b, end_stream: true)
      end

      def local_closed?
        @local_closed
      end

      def reset(error_code)
        @local_closed = true
        @connection.session.send_rst_stream(@id, error_code)
      end

      # The monotonic clock every deadline in the core is measured against.
      def self.now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Hands +frame+ to the transport, blocking only once more than
      # WRITE_HIGH_WATER bytes are queued but not yet on the socket.
      def queue_write(frame)
        size = frame.bytesize
        @write_mu.synchronize { @queued_bytes += size }
        ack = lambda do
          @write_mu.synchronize do
            @queued_bytes -= size
            @write_cv.broadcast
          end
        end
        @connection.session.send_data(@id, frame, ack: ack)
        @write_mu.synchronize do
          # The bounded wait keeps a lost acknowledgement from wedging the
          # caller; the transport fires every pending ack when it shuts down.
          @write_cv.wait(@write_mu, 1) while @queued_bytes > WRITE_HIGH_WATER
        end
      end

      # Raised when the peer stops mid-message.
      class Truncated < StandardError; end
      # Raised when a message exceeds grpc.max_receive_message_length.
      class ResourceExhausted < StandardError; end

      private

      def trailers_only?(pairs)
        pairs.any? { |name, _| name == 'grpc-status' }
      end

      def header_value(pairs, name)
        pairs.find { |n, _| n == name }&.last
      end

      # Blocks until +count+ bytes are buffered. Returns nil at a clean end of
      # stream, and raises the stream failure if one arrived first.
      def read_bytes(count, deadline)
        @mu.synchronize do
          wait_until(deadline) do
            @buffer.bytesize >= count || @eos || @failure
          end
          if @buffer.bytesize < count
            return nil if @buffer.empty?
            fail Truncated, 'truncated gRPC message' if @eos
            return nil
          end
          out = @buffer.byteslice(0, count)
          @buffer = @buffer.byteslice(count..) || +''.b
          out
        end
      end

      # Must be called with @mu held.
      def wait_until(deadline)
        until yield
          remaining = deadline && (deadline - RpcStream.now)
          if remaining
            return false if remaining <= 0
            @cv.wait(@mu, remaining)
          else
            @cv.wait(@mu)
          end
        end
        true
      end
    end
  end
end
