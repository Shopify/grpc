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

      # How much consumed prefix may sit in the receive buffer before it is
      # reclaimed. Only reached while a message is assembled from many frames.
      COMPACT_THRESHOLD = 64 * 1024

      # A message larger than one frame arrives in several chunks, and a
      # buffer that starts empty reallocates and copies what it already holds
      # on the way up. A chunk that fills a whole frame is a fair guess that
      # more of the message follows, so the buffer is given the room at once.
      # It is only a guess: nothing in the protocol promises it.
      #
      # The signal is bytes this side actually received, not a length the peer
      # claimed, so memory follows delivery: a stream that receives little
      # holds little and one that receives nothing holds nothing. The ratio
      # covers a message of a few frames without another growth, and bounds
      # what a peer can make this side hold to that multiple of what it sent.
      BUFFER_SIZE_TRIGGER = 16 * 1024
      BUFFER_SIZE_RATIO = 5

      # A ceiling on that, whatever the ratio would allow.
      BUFFER_SIZE_MAX = 1 << 20

      # The payload size at which reserving the whole frame up front starts to
      # pay for the keyword hash it costs. One frame: below this the message
      # is written in a single DATA frame and barely grows.
      FRAME_RESERVE_MIN = 16 * 1024

      EMPTY = ''.b.freeze

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
        # Bytes of @buffer already handed to the reader. Consuming with a
        # cursor keeps a read from copying the whole remainder.
        @read_pos = 0
        @eos = false
        # Monotonic instant the stream finished, however it finished.
        @terminated_at = nil
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

      # Takes +len+ buffered bytes from the frame reader straight into the
      # receive buffer. The reader has already made them available, so nothing
      # here blocks while the lock is held.
      def append_data(reader, len)
        @mu.synchronize do
          compact_locked
          size_buffer_locked(len)
          reader.append_into(@buffer, len)
          @cv.broadcast
        end
      end

      def push_data(chunk)
        @mu.synchronize do
          compact_locked
          size_buffer_locked(chunk.bytesize)
          @buffer << chunk
          @cv.broadcast
        end
      end

      # Drops the consumed prefix before it can dominate the buffer. A reader
      # that keeps up clears it in #advance instead, so this only runs while a
      # message is being assembled from many frames. Call with @mu held.
      def compact_locked
        return if @read_pos < COMPACT_THRESHOLD
        @buffer[0, @read_pos] = EMPTY
        @read_pos = 0
      end

      # Speculative: a chunk this large is usually one frame of a message that
      # needs several, so the buffer is given that much room at once rather
      # than reallocating and copying its way up. Nothing here promises more
      # data is coming; a message ending exactly on a frame boundary simply
      # leaves the extra room unused. The size test comes first, so a stream
      # of small messages fails it on one comparison and pays nothing else.
      # The buffer holds no data when this replaces it, so it loses nothing,
      # and it need not know where a message begins. Call with @mu held.
      def size_buffer_locked(incoming)
        return unless incoming >= BUFFER_SIZE_TRIGGER && @buffer.empty?
        want = incoming * BUFFER_SIZE_RATIO
        return if want > BUFFER_SIZE_MAX
        @buffer = String.new(encoding: Encoding::BINARY, capacity: want)
      end

      def push_trailers(pairs)
        @mu.synchronize do
          @trailers = pairs
          @terminated_at ||= RpcStream.now
          @cv.broadcast
        end
      end

      def push_eos
        @mu.synchronize do
          @eos = true
          @trailers ||= @headers if @headers && trailers_only?(@headers)
          @terminated_at ||= RpcStream.now
          @cv.broadcast
        end
      end

      def push_failure(code, details)
        @mu.synchronize do
          @failure ||= Failure.new(code, details)
          @eos = true
          @terminated_at ||= RpcStream.now
          @cv.broadcast
        end
      end

      # True when this stream had not finished by +deadline+, a monotonic
      # instant. A gRPC deadline is absolute: a status that reaches the client
      # after the deadline has already passed does not rescue the call, so the
      # arrival time is what decides, not whether a status turned up before
      # anybody got round to asking for it.
      def unfinished_at?(deadline)
        return false if deadline.nil?
        @mu.synchronize do
          @terminated_at.nil? || @terminated_at > deadline
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
        compressed = false
        length = 0
        # The five byte prefix is read in place: slicing it out allocated a
        # String and a second one for the length field, per message.
        @mu.synchronize do
          return nil unless await_bytes(FRAME_HEADER_SIZE, deadline)
          compressed = @buffer.getbyte(@read_pos) == 1
          length = @buffer.unpack1('N', offset: @read_pos + 1)
          advance(FRAME_HEADER_SIZE)
        end
        if @max_receive_message_length.positive? &&
           length > @max_receive_message_length
          fail ResourceExhausted,
               "Received message larger than max (#{length} vs. " \
               "#{@max_receive_message_length})"
        end
        return +''.b if length.zero?
        body = read_bytes(length, deadline)
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
      #
      # The payload is copied into the frame, and that copy is not optional.
      # This method returns while the frame is still queued, so anything kept
      # by reference would still be the transport's to write after the caller
      # got control back. A marshaller is free to hand out one reused buffer,
      # and gRPC's C extension copies into a byte buffer for the same reason.
      # Aliasing it here corrupted streamed messages, and because the length
      # prefix is fixed at this moment while the bytes were not, a payload
      # that changed size desynchronised the stream and killed the RPC.
      def send_message(payload, no_compress: false)
        flag = 0
        if !no_compress && @send_encoding != 'identity'
          payload = MessageCompression.compress(@send_encoding, payload)
          flag = 1
        end
        size = payload.bytesize
        # Reserving room up front is only worth its cost on a large payload.
        # String.new with a capacity takes a keyword hash, which is two extra
        # objects per message, and that outweighs the saved growth for small
        # ones: dropping it measured 11 per cent on empty unary and 6 per cent
        # on server streaming, while a 64 KiB payload wants the room. Plain
        # String.new is already binary, so both arms agree on encoding.
        frame = if size >= FRAME_RESERVE_MIN
                  String.new(encoding: Encoding::BINARY,
                             capacity: size + FRAME_HEADER_SIZE)
                else
                  String.new
                end
        frame << flag <<
          (size >> 24) << ((size >> 16) & 0xFF) <<
          ((size >> 8) & 0xFF) << (size & 0xFF)
        # Appends the bytes whatever the payload's encoding, and never leaves
        # the buffer tagged as anything but binary.
        Http2::Kantan::H2::Body.append_bytes(frame, payload)
        queue_write(frame, frame.bytesize)
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
      # WRITE_HIGH_WATER bytes are queued but not yet written.
      #
      # +frame+ is a String, or an Array of segments to be written back to
      # back. +size+ is their total. It has no default on purpose: an Array
      # has no #bytesize, so a default would only work for one of the two
      # shapes and fail late on the other.
      def queue_write(frame, size)
        @write_mu.synchronize { @queued_bytes += size }
        @connection.session.send_data(@id, frame, ack_to: self, ack_size: size)
        @write_mu.synchronize do
          # The bounded wait keeps a lost acknowledgement from wedging the
          # caller; the transport fires every pending ack when it shuts down.
          @write_cv.wait(@write_mu, 1) while @queued_bytes > WRITE_HIGH_WATER
        end
      end

      # Called from the write thread once +size+ bytes of this stream have
      # left the body queue for the write buffer. This is the receiver the
      # queue holds instead of a closure, so a client that streams does not
      # allocate a lambda for every message it sends.
      def ack_write(size)
        @write_mu.synchronize do
          @queued_bytes -= size
          @write_cv.broadcast
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
          return nil unless await_bytes(count, deadline)
          out = @buffer.byteslice(@read_pos, count)
          advance(count)
          out
        end
      end

      # Must be called with @mu held. True once +count+ bytes are buffered.
      # False at a clean end of stream or an expired deadline; raises when the
      # peer stopped part way through a message.
      def await_bytes(count, deadline)
        wait_until(deadline) { buffered >= count || @eos || @failure }
        return true if buffered >= count
        return false if buffered.zero?
        fail Truncated, 'truncated gRPC message' if @eos
        false
      end

      # Must be called with @mu held.
      def buffered
        @buffer.bytesize - @read_pos
      end

      # Must be called with @mu held. Marks +count+ bytes consumed, and hands
      # the storage back once the reader has caught up with the writer.
      def advance(count)
        @read_pos += count
        return if @read_pos < @buffer.bytesize
        @buffer.clear
        @read_pos = 0
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
