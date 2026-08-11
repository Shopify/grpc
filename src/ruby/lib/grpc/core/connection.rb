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

      # gRPC waits 20 seconds for a keepalive PING to be acknowledged.
      DEFAULT_KEEPALIVE_TIMEOUT = 20.0

      # grpc.http2.max_pings_without_data and grpc.http2.max_ping_strikes:
      # C-core defaults both to 2.
      DEFAULT_MAX_PINGS_WITHOUT_DATA = 2
      DEFAULT_MAX_PING_STRIKES = 2

      # grpc.http2.lookahead_bytes: C-core's own default. Session already
      # advertises a receive window far above this, so it only matters when
      # a caller raises it past that floor to unlock more BDP-driven growth.
      DEFAULT_LOOKAHEAD_BYTES = 65_536

      # How often the maintenance timer wakes to re-check every deadline
      # (keepalive, idle, age). Finer than any one interval so several
      # features sharing the thread do not lose precision to each other.
      MAINTENANCE_POLL_INTERVAL = 0.005

      attr_reader :session, :peer, :peer_cert
      # Set by Subchannel#connect_worker right after a successful dial, to
      # whatever CallCounter OutlierDetectionPolicy gave that address (nil
      # when outlier detection is not configured). Call#op_recv_status bumps
      # it once per finished client RPC; nothing else touches it.
      attr_accessor :outlier_counter
      # Set by Subchannel#connect_worker right after a successful dial, to
      # whatever XdsClient::LrsCallCounter the resolved address's cluster

      # rubocop:disable Metrics/ParameterLists -- all but +io+ are keywords
      def initialize(io, peer:, client:, max_receive_message_length:,
                     max_send_message_length: RpcStream::NO_LIMIT,
                     max_concurrent_streams: 100, peer_cert: nil,
                     keepalive_time: nil, keepalive_timeout: DEFAULT_KEEPALIVE_TIMEOUT,
                     keepalive_permit_without_calls: false,
                     max_connection_idle: nil, max_connection_age: nil,
                     max_connection_age_grace: nil, client_idle_timeout: nil,
                     max_pings_without_data: DEFAULT_MAX_PINGS_WITHOUT_DATA,
                     min_time_between_pings: nil,
                     max_ping_strikes: DEFAULT_MAX_PING_STRIKES,
                     bdp_probe: true, lookahead_bytes: nil, max_frame_size: nil,
                     write_buffer_size: nil, handshake_timeout: nil,
                     on_new_rpc: nil, on_close: nil)
        super()
        @io = io
        @peer = peer
        @peer_cert = peer_cert
        @client = client
        @max_receive_message_length = max_receive_message_length
        @max_send_message_length = max_send_message_length
        @keepalive_time = keepalive_time
        @keepalive_timeout = keepalive_timeout
        @keepalive_permit_without_calls = keepalive_permit_without_calls
        @max_connection_idle = max_connection_idle
        @max_connection_age = max_connection_age
        @max_connection_age_grace = max_connection_age_grace
        @client_idle_timeout = client_idle_timeout
        # grpc.http2.max_pings_without_data (0 = unlimited) and
        # grpc.http2.min_time_between_pings_ms bound how often *this* side
        # sends a keepalive PING, on top of grpc.keepalive_time_ms itself.
        @max_pings_without_data = max_pings_without_data
        @min_time_between_pings = min_time_between_pings
        @pings_without_data = 0
        @last_ping_sent_at = nil
        @data_frames_sent_at_last_ping = 0
        @maintenance_thread = nil
        # grpc.server_handshake_timeout_ms: server-side only (nil on the
        # client, which awaits its own handshake synchronously in
        # Channel#connect_worker); the watchdog thread that enforces it.
        @handshake_timeout = handshake_timeout
        @handshake_thread = nil
        # Set while a PING we sent has not been acknowledged. The reader
        # thread clears it through #on_ping.
        @ping_deadline = nil
        # Set once GOAWAY has gone out for exceeding max_connection_age; new
        # streams are refused from then on and only the grace deadline (if
        # any) or the last RPC draining can still close the connection.
        @goaway_sent = false
        @age_grace_deadline = nil
        @created_at = nil
        # Set once a GOAWAY has been *received* from the peer: no new stream
        # is offered from then on, and the connection closes itself once
        # every stream at or below the peer's last_stream_id has finished.
        @draining = false
        # The moment @streams last became empty, i.e. the start of the
        # current idle period; nil while an RPC is in flight.
        @idle_since = nil
        @on_new_rpc = on_new_rpc
        @on_close = on_close
        @streams = {}
        @mu = Mutex.new
        @closed = false
        @started = false
        @handshaked = false
        @handshake_cv = ConditionVariable.new
        @session = Http2::Kantan::H2::Session.new(
          io, handler: self, max_concurrent_streams: max_concurrent_streams,
              max_ping_strikes: max_ping_strikes, bdp_probe: bdp_probe,
              lookahead_bytes: lookahead_bytes, max_frame_size: max_frame_size,
              write_buffer_size: write_buffer_size)
      end
      # rubocop:enable Metrics/ParameterLists

      def client?
        @client
      end

      def start
        @mu.synchronize do
          @started = true
          @created_at = RpcStream.now
          @idle_since = @created_at
        end
        # #start_handshake_watchdog has to run concurrently with, not after,
        # the branch below: for a server that call blocks reading the
        # connection preface for as long as the peer takes to send it, which
        # is exactly the case grpc.server_handshake_timeout_ms guards
        # against.
        start_handshake_watchdog unless @client
        @client ? @session.connect : @session.receive
        start_maintenance
        self
      end

      # grpc.server_handshake_timeout_ms: a peer that never drives the
      # connection to a completed HTTP/2 handshake would otherwise hold the
      # accepting thread and its socket forever, since the preface read
      # above has no timeout of its own. Reuses #await_handshake -- the
      # same wait a client performs synchronously after #connect -- instead
      # of adding a second wait/notify path.
      def start_handshake_watchdog
        return unless @handshake_timeout
        @handshake_thread = Thread.new do
          Thread.current.name = 'conn-handshake'
          begin
            await_handshake(@handshake_timeout)
          rescue Closed
            close(StatusCodes::DEADLINE_EXCEEDED,
                  'peer never completed the HTTP/2 handshake')
          end
        end
      end

      # Mirrors #stop_maintenance: the watchdog may be the very thread
      # calling #close (on timeout), and Thread#join on the current thread
      # raises ThreadError, so that case is skipped rather than guarded with
      # a rescue.
      def stop_handshake_watchdog
        thread = @mu.synchronize do
          t = @handshake_thread
          @handshake_thread = nil
          t
        end
        return if thread.nil? || thread == Thread.current
        thread.join(1)
        nil
      end

      # One thread services keepalive pings, server-side idle/age limits and
      # the client-side idle timeout, so a connection with several of these
      # configured still costs a single thread rather than one per feature.
      def start_maintenance
        return unless @keepalive_time || @max_connection_idle ||
                      @max_connection_age || @client_idle_timeout
        @maintenance_thread = Thread.new do
          Thread.current.name = 'conn-maintenance'
          maintenance_loop
        end
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

      # The peer acknowledged our PING, so the connection is alive. Called by
      # the session's reader thread.
      def on_ping(_rtt_ns)
        @mu.synchronize { @ping_deadline = nil }
      end

      # The peer will not process anything above +last_stream_id+, so this
      # connection stops offering new streams and starts winding down:
      # streams already accepted keep running to completion, anything past
      # that boundary was never seen by the peer and is safe to retry
      # elsewhere, and the connection closes itself once nothing is left on
      # it -- the resulting #on_close is what lets a Subchannel notice and
      # dial a fresh connection on the next call. Called by the session's
      # reader thread; does *not* tear the session down itself (see
      # Session#handle_goaway), so in-flight RPCs keep reading and writing.
      def on_goaway(last_stream_id, _error_code)
        refused = @mu.synchronize do
          return if @closed
          @draining = true
          @streams.each_key.select { |id| id > last_stream_id }
                           .each_with_object({}) { |id, acc| acc[id] = @streams.delete(id) }
        end
        refused.each_value do |stream|
          stream.push_failure(StatusCodes::UNAVAILABLE,
                              'stream never reached the peer before its GOAWAY')
        end
        close_if_drained
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
          fail Closed, 'connection is draining after a GOAWAY from the peer' if @draining
          id = @session.new_stream
          @streams[id] = new_stream(id)
        end
      end

      # Marks when the last RPC finished, so the maintenance loop can measure
      # how long the connection has sat with nothing running on it.
      def forget(stream_id)
        drained = @mu.synchronize do
          @streams.delete(stream_id)
          @idle_since = RpcStream.now if @streams.empty?
          @draining && @streams.empty?
        end
        close(StatusCodes::UNAVAILABLE, 'connection drained after a GOAWAY from the peer') if drained
      end

      # Sends GOAWAY and tears the socket down, failing every live RPC.
      def close(status = StatusCodes::UNAVAILABLE, details = 'Transport closed')
        started = @mu.synchronize do
          return if @closed
          @closed = true
          @started
        end
        if started && @session.running?
          # The session's write thread drains the queue and closes the socket.
          @session.shutdown
        else
          # Either #start was never called, or it is still blocked reading
          # the connection preface (grpc.server_handshake_timeout_ms): in
          # both cases no writer thread exists to drain a #shutdown command,
          # so the socket has to be closed directly or it leaks. Closing it
          # here also unblocks that pending preface read with an IOError.
          begin
            @io.close
          rescue StandardError
            nil
          end
        end
        stop_maintenance
        stop_handshake_watchdog
        fail_all(status, details)
        nil
      end

      # The loop wakes on its own interval, so closing only has to mark the
      # connection closed and wait for it to notice; a leaked thread per
      # connection would outlive every RPC on it. A limit crossing closes
      # the connection from inside this very thread (e.g. a keepalive
      # timeout or an expired grace period), so joining it here would
      # deadlock -- Thread#join on the current thread raises ThreadError --
      # and there is nothing left to wait for anyway.
      def stop_maintenance
        thread = @mu.synchronize do
          t = @maintenance_thread
          @maintenance_thread = nil
          t
        end
        return if thread.nil? || thread == Thread.current
        thread.wakeup if thread.alive?
        thread.join(1)
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

      # The payload is still in the frame reader's buffer, so it goes straight
      # into the stream's receive buffer. Cutting a String out for it first
      # was the largest single allocation site in an RPC.
      def on_data_into(kstream, reader, len)
        stream = @mu.synchronize { @streams[kstream.id] }
        return reader.skip(len) if stream.nil?
        stream.append_data(reader, len)
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

      # Called after a GOAWAY has finished refusing streams above
      # last_stream_id: if nothing was left running below it, the
      # connection is already fully drained and there is nothing left to
      # wait for.
      def close_if_drained
        drained = @mu.synchronize { @draining && @streams.empty? }
        close(StatusCodes::UNAVAILABLE, 'connection drained after a GOAWAY from the peer') if drained
      end

      # Runs every MAINTENANCE_POLL_INTERVAL and drives whichever of
      # keepalive, the server-side idle/age limits, and the client-side idle
      # timeout this connection was configured with. Polling on a short,
      # shared tick keeps every configured deadline accurate to
      # MAINTENANCE_POLL_INTERVAL, however many of them are active together.
      def maintenance_loop
        next_ping_at = @keepalive_time && (RpcStream.now + @keepalive_time)
        until @mu.synchronize { @closed }
          sleep(MAINTENANCE_POLL_INTERVAL)
          break if @mu.synchronize { @closed }
          now = RpcStream.now
          if @keepalive_time
            next_ping_at, closed = check_keepalive(now, next_ping_at)
            break if closed
          end
          break if check_idle_limits(now)
          break if check_max_age(now)
        end
      rescue StandardError => e
        GRPC.logger.debug("connection maintenance stopped: #{e.class}: #{e.message}")
      end

      # Sends a PING and expects it acknowledged within +keepalive_timeout+.
      # gRPC only pings an otherwise-idle connection when the caller opted
      # in, because a ping with no RPC in flight is what upsets strict peers.
      #
      # @return [Array(Float, Boolean)] the next ping deadline, and whether
      #   this closed the connection
      def check_keepalive(now, next_ping_at)
        expired = @mu.synchronize do
          deadline = @ping_deadline
          !deadline.nil? && now >= deadline
        end
        if expired
          close(StatusCodes::UNAVAILABLE, 'keepalive ping timed out')
          return [next_ping_at, true]
        end
        note_data_sent_since_last_ping
        return [next_ping_at, false] if now < next_ping_at
        send_keepalive_ping(now) if ping_permitted? && ping_policing_permits?(now)
        [now + @keepalive_time, false]
      end

      # grpc.http2.max_pings_without_data: a data or header frame sent on
      # this connection since the last time this ran means the peer is not
      # starved for activity, so any pings already counted against the
      # limit no longer apply.
      def note_data_sent_since_last_ping
        sent = @session.data_frames_sent
        return if sent == @data_frames_sent_at_last_ping
        @data_frames_sent_at_last_ping = sent
        @pings_without_data = 0
      end

      # grpc.http2.max_pings_without_data (0 = unlimited) and
      # grpc.http2.min_time_between_pings_ms both bound how often *this*
      # side may send a keepalive PING, independently of how often
      # grpc.keepalive_time_ms would otherwise ask for one.
      def ping_policing_permits?(now)
        return false if @max_pings_without_data.positive? &&
                        @pings_without_data >= @max_pings_without_data
        return false if @min_time_between_pings &&
                        @last_ping_sent_at &&
                        now - @last_ping_sent_at < @min_time_between_pings
        true
      end

      def send_keepalive_ping(now)
        @mu.synchronize { @ping_deadline = now + @keepalive_timeout if @ping_deadline.nil? }
        @session.ping
        @pings_without_data += 1
        @last_ping_sent_at = now
      rescue StandardError
        # The write side is already gone; the reader will finish the job.
        nil
      end

      def ping_permitted?
        return true if @keepalive_permit_without_calls
        @mu.synchronize { !@streams.empty? }
      end

      # grpc.max_connection_idle_ms (server) and grpc.client_idle_timeout_ms
      # (client) are the same measurement -- time since the last RPC closed
      # -- read from opposite ends of the connection. A client-side timeout
      # closes the connection outright: Channel#on_connection_closed sees
      # the resulting on_close callback and drops the channel back to IDLE,
      # so the next call reconnects instead of reusing a dead transport.
      #
      # @return [Boolean] whether this closed the connection
      def check_idle_limits(now)
        limit = @client ? @client_idle_timeout : @max_connection_idle
        return false if limit.nil?
        idle_for = @mu.synchronize { @streams.empty? ? now - @idle_since : 0 }
        return false if idle_for < limit
        close(StatusCodes::UNAVAILABLE,
              @client ? 'client idle timeout' : 'connection idle for too long')
        true
      end

      # grpc.max_connection_age_ms: GOAWAY goes out once the connection gets
      # too old, and in-flight RPCs are given until
      # grpc.max_connection_age_grace_ms to finish -- forever, if that is
      # unset -- before the connection is cut regardless. A connection is
      # never cut mid-RPC before that grace deadline.
      #
      # @return [Boolean] whether this closed the connection
      def check_max_age(now)
        return false if @client || @max_connection_age.nil?
        send_age_goaway(now) unless @mu.synchronize { @goaway_sent }
        return false unless @mu.synchronize { @goaway_sent }
        drained = @mu.synchronize { @streams.empty? }
        grace_expired = @mu.synchronize do
          !@age_grace_deadline.nil? && now >= @age_grace_deadline
        end
        return false unless drained || grace_expired
        close(StatusCodes::UNAVAILABLE, 'connection reached max age')
        true
      end

      def send_age_goaway(now)
        return if now - @created_at < @max_connection_age
        @mu.synchronize do
          return if @goaway_sent
          @goaway_sent = true
          @age_grace_deadline = @max_connection_age_grace &&
                                (now + @max_connection_age_grace)
        end
        begin
          @session.send_goaway
        rescue StandardError
          # The write side is already gone; the reader will finish the job.
          nil
        end
      end

      def new_stream(id)
        stream = RpcStream.new(
          self, id,
          max_receive_message_length: @max_receive_message_length,
          max_send_message_length: @max_send_message_length)
        stream.peer = @peer
        stream.peer_cert = @peer_cert
        stream
      end

      # Server side: a HEADERS block on an unknown stream starts a new RPC.
      # Once GOAWAY has gone out for max_connection_age, no new stream is
      # accepted -- that is the point of GOAWAY -- even though existing ones
      # keep running until they finish or the grace period expires.
      def accept(kstream)
        stream = @mu.synchronize do
          return nil if @closed || @goaway_sent
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
