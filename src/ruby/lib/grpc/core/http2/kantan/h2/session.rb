# frozen_string_literal: true

# Vendored from kantan (https://github.com/tenderlove/kantan), Copyright
# Aaron Patterson, distributed under the Apache License 2.0 -- the same
# licence as gRPC. The code is namespaced under GRPC::Core::Http2 so that it
# cannot collide with a separately installed kantan gem.
#
# Local modifications are marked with "grpc:" comments.

module GRPC
  module Core
    module Http2
require_relative "../h2/hpack"
require_relative "../h2/frames"
require_relative "../h2/body"
require_relative "../errors"
require_relative "../stream"
require "securerandom"
require "openssl"

module Kantan
  module H2
    # The +io+ object passed to Session must implement the following methods:
    #
    #   read(n)        Read exactly +n+ bytes, blocking until all bytes are
    #                  available. Returns a binary-encoded String, or +nil+ at
    #                  EOF.
    #
    #   readbyte       Read and return a single byte as an Integer (0-255).
    #                  Raises EOFError at end of stream.
    #
    #   write(data)    Write +data+ (a binary String) to the peer.
    #
    #   close          Close the underlying transport.
    #
    # Any Ruby IO, TCPSocket, OpenSSL::SSL::SSLSocket, or one half of a
    # Socket.pair(:UNIX, :STREAM) satisfies this interface out of the box.
    class Session
      MAX_HEADER_LIST_SIZE = 65536
      MAX_PENDING_BODY_SIZE = 1_048_576
      WRITE_BUFFER_SIZE = 65536

      CONNECTION_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".b.freeze

      # grpc: reads frames through one reusable buffer.
      #
      # The frame loop used to call io.read(9) for every header and io.read(n)
      # for every payload, so each frame cost at least two Strings and an
      # unpack Array. This refills a single 64 KiB buffer with
      # IO#readpartial(size, buf), which writes into the String already
      # allocated here, and then reads integers straight out of it with
      # getbyte and unpack1(offset:). Only payloads that outlive the buffer,
      # such as a DATA chunk or a header block, are copied out.
      class FrameReader
        CHUNK = 65_536
        EMPTY = ""

        attr_reader :length, :type, :flags, :stream_id

        def initialize io
          @io = io
          @buf = String.new(encoding: Encoding::BINARY, capacity: CHUNK)
          @scratch = String.new(encoding: Encoding::BINARY, capacity: CHUNK)
          @pos = 0
          @length = @type = @flags = @stream_id = 0
        end

        # Decodes the next 9 byte frame header into the readers above.
        # Returns false at a clean end of stream.
        def next_frame
          return false unless fill(9)
          buf = @buf
          pos = @pos
          @length = (buf.getbyte(pos) << 16) |
                    (buf.getbyte(pos + 1) << 8) |
                    buf.getbyte(pos + 2)
          @type = buf.getbyte(pos + 3)
          @flags = buf.getbyte(pos + 4)
          @stream_id = buf.unpack1("N", offset: pos + 5) & 0x7FFF_FFFF
          @pos = pos + 9
          true
        end

        # Copies +count+ bytes out. Used only where the bytes outlive the
        # buffer.
        def read count
          return +"".b if count.zero?
          return nil unless fill(count)
          out = @buf.byteslice(@pos, count)
          @pos += count
          out
        end

        def readbyte
          raise EOFError unless fill(1)
          byte = @buf.getbyte(@pos)
          @pos += 1
          byte
        end

        # Big-endian integers, read in place.
        def read_uint32
          raise EOFError unless fill(4)
          value = @buf.unpack1("N", offset: @pos)
          @pos += 4
          value
        end

        def read_uint64
          raise EOFError unless fill(8)
          value = @buf.unpack1("Q>", offset: @pos)
          @pos += 8
          value
        end

        # Reads a run of 6 byte SETTINGS entries without copying them.
        def each_setting count
          count.times do
            raise EOFError unless fill(6)
            pos = @pos
            @pos += 6
            yield @buf.unpack1("n", offset: pos),
                  @buf.unpack1("N", offset: pos + 2)
          end
        end

        # Drops +count+ bytes.
        def skip count
          while count.positive?
            available = @buf.bytesize - @pos
            if available >= count
              @pos += count
              return true
            end
            count -= available
            @pos = @buf.bytesize
            return false unless refill
          end
          true
        end

        private

        # Makes at least +need+ bytes available, or returns false at EOF.
        def fill need
          while @buf.bytesize - @pos < need
            return false unless refill
          end
          true
        end

        def refill
          if @pos == @buf.bytesize
            # Nothing is pending, so the buffer's storage can be reused whole:
            # IO#readpartial overwrites it and keeps the allocation it already
            # has.
            @pos = 0
            begin
              @io.readpartial(CHUNK, @buf)
            rescue IOError
              # The invariant this relies on is that a failed refill leaves
              # nothing readable, or the bytes just consumed stay visible and
              # the next caller parses them again as a frame. IO#readpartial
              # empties the buffer before EOFError but not before a closed
              # stream error, so it is emptied here instead.
              #
              # #clear frees the buffer's storage rather than keeping it, so
              # doing this on every read cost a 64 KiB allocation per frame
              # read. Here it runs once, as the connection dies.
              @buf.clear
              raise
            end
          else
            # A frame straddles the end of the buffer. Drop what was already
            # consumed, then append, so the buffer cannot grow without bound.
            if @pos.positive?
              @buf[0, @pos] = EMPTY
              @pos = 0
            end
            @buf << @io.readpartial(CHUNK, @scratch)
          end
          true
        rescue EOFError
          false
        end
      end

      # grpc: how many received bytes may go unacknowledged before a
      # WINDOW_UPDATE is due. Half the window, so the peer always has room
      # left when the acknowledgement goes out.
      RECEIVE_WINDOW = Frames::Settings::ADVERTISED_INITIAL_WINDOW_SIZE
      WINDOW_UPDATE_THRESHOLD = RECEIVE_WINDOW / 2

      # grpc: SETTINGS carries the per-stream window, but the connection window
      # can only be raised with a WINDOW_UPDATE on stream 0. Without this the
      # connection stays at the 65535 byte default and throttles every stream
      # on it, whatever they were promised individually.
      CONNECTION_WINDOW_BUMP = [
        (4 << 8) | 0x8, 0, 0, RECEIVE_WINDOW - 65_535
      ].pack("NCNN").freeze

      # grpc: writes the 9 byte frame header without the Array that
      # [len_type, flags, id].pack("NCN", buffer: buf) allocates for every
      # frame. Appending the bytes measured about 1.8 times faster.
      def write_frame_header buf, length, type, flags, stream_id
        buf << (length >> 16) << ((length >> 8) & 0xFF) << (length & 0xFF) <<
               type << flags <<
               (stream_id >> 24) << ((stream_id >> 16) & 0xFF) <<
               ((stream_id >> 8) & 0xFF) << (stream_id & 0xFF)
      end

      # grpc: returns +len+ bytes of connection level window without touching a
      # stream. DATA that this endpoint discards -- because the stream was
      # reset locally, or had already closed -- has still spent the peer's
      # connection window. Never returning it leaks the window for good, and a
      # peer that cancels calls often would eventually stall every other
      # stream on the connection.
      def credit_connection_window len
        return unless len.positive?
        @connection_unacked += len
        return if @connection_unacked < WINDOW_UPDATE_THRESHOLD
        @write_queue << [:send_window_update, 0, @connection_unacked, 0]
        @connection_unacked = 0
      end

      # grpc: appends a big-endian 32 bit value.
      def write_uint32 buf, value
        buf << (value >> 24) << ((value >> 16) & 0xFF) <<
               ((value >> 8) & 0xFF) << (value & 0xFF)
      end

      # grpc: GOAWAY carries the last stream id and an error code.
      def write_goaway_frame buf, error_code
        write_frame_header buf, 8, 0x7, 0, 0
        write_uint32 buf, @highest_stream_id
        write_uint32 buf, error_code
      end

      # grpc: max_concurrent_streams is configurable so that a gRPC server can
      # honour grpc.max_concurrent_streams from its channel args.
      def initialize io, handler:, max_concurrent_streams: 100
        @name = SecureRandom.uuid
        @io = io
        @handler = handler

        # Table used to encode values sent to the peer (owned by write thread)
        @encoding_table = HPACK.new

        # Table used to decode values sent by the peer (owned by read thread)
        @decoding_table = HPACK.new

        @peer_settings = Frames::Settings.new(
          0,
          4096, # default header table size,
          1,    # default enable_push
          -1,   # default value max concurrent streams (-1 for unlimited)
          65535, # initial window size
          16384, # initial max frame size
          -1,    # max header list size (-1 for not set)
        )

        @connection_window = 65535
        # grpc: received bytes not yet returned to the peer, connection wide.
        @connection_unacked = 0
        @write_queue = Thread::Queue.new
        @next_stream_id = 1
        @streams = {}
        @highest_stream_id = 0 # Track highest stream ID seen from peer
        @open_stream_count = 0 # Track concurrent open streams
        @pending_body_size = 0
        # grpc: streams with something queued to write, by id. flush_pending
        # walks this instead of every live stream.
        @active_bodies = {}
        @local_max_concurrent_streams = max_concurrent_streams
        # grpc: streams we reset locally. Frames the peer had already put on
        # the wire for them are discarded instead of failing the connection.
        @locally_reset = {}

        # CONTINUATION frame state
        @expecting_continuation = false
        @continuation_stream_id = nil
        @header_buffer = nil
        @continuation_flags = nil

        # Server vs client mode (nil until connect/receive is called)
        @server_mode = nil
      end

      # grpc: one place that knows the Stream layout, and the only place that
      # seeds the unacknowledged byte counter.
      def build_stream stream_id
        Stream.new(stream_id, nil, 0, self, :idle,
                   @peer_settings.initial_window_size, false, nil, false, nil, 0)
      end

      def new_stream
        stream_id = @next_stream_id
        @next_stream_id += 2
        stream = build_stream(stream_id)
        @streams[stream_id] = stream
        stream_id
      end

      def send_headers stream_id, headers, has_body: false
        @write_queue << [:headers, stream_id, headers, !has_body]
      end

      def send_body stream_id, body
        body = body.b if body.encoding != Encoding::BINARY
        @write_queue << [:data, stream_id, body]
      end

      def send_file stream_id, path
        @write_queue << [:sendfile, stream_id, path]
      end

      # grpc: appends one DATA chunk without necessarily ending the stream.
      # +ack+ is invoked from the write thread once the chunk has left the
      # queue for the transport's write buffer, which lets a caller apply
      # flow-control backpressure.
      #
      # +data+ becomes the transport's to write after this returns, so the
      # caller must not keep hold of it. RpcStream#send_message copies for
      # exactly that reason.
      def send_data stream_id, data, end_stream: false, ack_to: nil,
                    ack_size: 0
        @write_queue << [:grpc_data, stream_id, data, end_stream, ack_to,
                         ack_size]
      end

      # grpc: writes the trailing HEADERS block once queued DATA has drained.
      def send_trailers stream_id, headers
        @write_queue << [:grpc_trailers, stream_id, headers]
      end

      # grpc: aborts a single stream without touching the connection.
      def send_rst_stream stream_id, error_code
        @write_queue << [:grpc_rst, stream_id, error_code]
      end

      # grpc: sends GOAWAY and stops the session without joining, so that a
      # caller already inside a session callback cannot deadlock on itself.
      def shutdown error_code = 0x0
        @write_queue << [:goaway, error_code]
        @write_queue << [:shutdown]
      end

      def request headers, body: nil
        stream_id = new_stream
        send_headers stream_id, headers, has_body: !!body
        send_body stream_id, body if body
        stream_id
      end

      def finish
        @write_queue << [:goaway, 0x0]
        @write_queue << [:shutdown]
        join
      end

      def join
        @writer&.join
        @reader&.join
      end

      def connect
        @server_mode = false
        @io.write CONNECTION_PREFACE
        @io.write Frames::Settings::DEFAULT_ENCODED
        @io.write CONNECTION_WINDOW_BUMP
        start_write_thread
        start_read_thread
      end

      def receive preface_verified: false
        @server_mode = true
        unless preface_verified
          preface = @io.read CONNECTION_PREFACE.bytesize
          if preface != CONNECTION_PREFACE
            send_goaway_frame @io, 0x1 # PROTOCOL_ERROR
            @io.close
            return
          end
        end
        @io.write Frames::Settings::DEFAULT_ENCODED
        @io.write CONNECTION_WINDOW_BUMP
        start_write_thread
        start_read_thread
      end

      def ping
        ts = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        @write_queue << [:ping, [ts].pack("Q>")]
      end

      private

      def validate_headers headers, stream_id, is_trailer
        # Track pseudo-headers and regular headers
        seen_regular_header = false
        content_length = nil

        pseudo_headers = 0

        headers.each do |name, value|
          if name.getbyte(0) == 58 # starts with :
            raise Errors::StreamError.new("Pseudo-header in trailers", stream_id) if is_trailer
            raise Errors::StreamError.new("Pseudo-header after regular header", stream_id) if seen_regular_header

            case name
            when ":method"
              raise Errors::StreamError.new("Duplicate pseudo-header", stream_id) if pseudo_headers.odd?
              pseudo_headers |= 0x01
            when ":scheme"
              raise Errors::StreamError.new("Duplicate pseudo-header", stream_id) if pseudo_headers[1].positive?
              pseudo_headers |= 0x02
            when ":path"
              raise Errors::StreamError.new("Duplicate pseudo-header", stream_id) if pseudo_headers[2].positive?
              raise Errors::StreamError.new("Empty :path", stream_id) if value.empty?
              pseudo_headers |= 0x04
            when ":authority"
              raise Errors::StreamError.new("Duplicate pseudo-header", stream_id) if pseudo_headers[3].positive?
              pseudo_headers |= 0x08
            when ":status"
              raise Errors::StreamError.new("Duplicate pseudo-header", stream_id) if pseudo_headers[4].positive?
              raise Errors::StreamError.new("Response pseudo-header in request", stream_id) if @server_mode
              pseudo_headers |= 0x10
            else
              raise Errors::StreamError.new("Unknown pseudo-header", stream_id)
            end
          else
            seen_regular_header = true
            case name
              # Connection-specific headers that are not allowed
            when "connection", "keep-alive", "proxy-connection", "transfer-encoding upgrade"
              raise Errors::StreamError.new("Forbidden connection header", stream_id)
            when "te"
              raise Errors::StreamError.new("Invalid TE value", stream_id) if value != "trailers"
            when "content-length"
              content_length = value.to_i
            end
          end
        end

        # Check required pseudo-headers for requests (server mode)
        if @server_mode && !is_trailer
          unless pseudo_headers & 0x7 == 0x7
            raise Errors::StreamError.new("Missing required pseudo-header", stream_id)
          end
        end

        content_length
      end

      # ── Write thread ──────────────────────────────────────────────────────

      def start_write_thread
        @writer = Thread.new {
          Thread.current.name = "writer - " + @name
          write_loop(@io)
        }
      end

      def write_loop io
        wbuf = String.new(encoding: Encoding::BINARY, capacity: WRITE_BUFFER_SIZE)

        while true
          # grpc: flush before blocking on the queue, not only after handling a
          # command. Several branches below skip the rest of the iteration with
          # +next+ when their stream has gone, which used to jump straight past
          # the flush at the bottom and leave a finished frame -- a PING ACK,
          # say -- sitting in the buffer while this thread waited for work that
          # never came. The peer then saw an open connection that had stopped
          # answering.
          if wbuf.bytesize.positive? && @write_queue.empty?
            io.write wbuf
            wbuf.clear
          end

          cmd = @write_queue.pop
          break unless cmd

          case cmd[0]
          when :headers
            _, stream_id, headers, end_stream = cmd
            stream = @streams[stream_id]
            next unless stream

            hpack = @encoding_table.encode headers
            flags = 0x04 # END_HEADERS
            flags |= 0x01 if end_stream

            write_frame_header wbuf, hpack.bytesize, 0x1, flags, stream_id
            wbuf << hpack

            if stream.idle?
              stream.open!
              @open_stream_count += 1
            end

            if end_stream
              stream.half_close_local!
              if stream.closed?
                @streams.delete(stream_id)
                @open_stream_count -= 1
              end
            end

          when :data
            _, stream_id, data = cmd
            stream = @streams[stream_id]
            next unless stream

            # grpc: bodies are queued so that several writes can be in flight,
            # and the stream only half-closes once the queue is marked ended.
            body = body_for(stream)
            body.push_data data
            body.end!
            @pending_body_size += data.bytesize
            flush_pending wbuf

          when :sendfile
            _, stream_id, path = cmd
            stream = @streams[stream_id]
            next unless stream

            part = Body::File.new(path)
            body = body_for(stream)
            body.push_part part
            body.end!
            @pending_body_size += part.bytesize
            flush_pending wbuf

          when :grpc_data
            _, stream_id, data, end_stream, ack_to, ack_size = cmd
            stream = @streams[stream_id]
            unless stream
              ack_to&.ack_write(ack_size)
              next
            end

            body = body_for(stream)
            body.push_data data, ack_to, ack_size
            @pending_body_size += data.bytesize
            body.end! if end_stream
            flush_pending wbuf

          when :grpc_trailers
            _, stream_id, headers = cmd
            stream = @streams[stream_id]
            next unless stream

            body = body_for(stream)
            body.end! headers
            flush_pending wbuf

          when :grpc_rst
            _, stream_id, error_code = cmd
            stream = @streams.delete(stream_id)
            next unless stream

            write_frame_header wbuf, 4, 0x3, 0, stream_id
            write_uint32 wbuf, error_code
            @locally_reset[stream_id] = true
            @active_bodies.delete(stream_id)
            if stream.body
              @pending_body_size -= stream.body.bytesize
              stream.body.close
              stream.body = nil
            end
            stream.close!
            @open_stream_count -= 1

          when :ping
            _, payload = cmd
            wbuf << "\x00\x00\x08\x06\x00\x00\x00\x00\x00"
            wbuf << payload

          when :ping_ack
            _, payload = cmd
            wbuf << "\x00\x00\x08\x06\x01\x00\x00\x00\x00"
            wbuf << payload

          when :settings_ack
            wbuf << "\x00\x00\x00\x04\x01\x00\x00\x00\x00"

          when :rst_stream
            _, stream_id, error_code = cmd
            write_frame_header wbuf, 4, 0x3, 0, stream_id
            write_uint32 wbuf, error_code

          when :goaway
            _, error_code = cmd
            write_goaway_frame wbuf, error_code

          when :window_update
            _, stream_id, increment = cmd
            stream_overflow = false
            if stream_id.zero?
              @connection_window += increment
              if @connection_window > 0x7FFF_FFFF
                write_goaway_frame wbuf, 0x3
                break
              end
            else
              stream = @streams[stream_id]
              if stream
                stream.window_size += increment
                if stream.window_size > 0x7FFF_FFFF
                  write_frame_header wbuf, 4, 0x3, 0, stream_id
                  write_uint32 wbuf, 0x3
                  stream_overflow = true
                end
              end
            end
            flush_pending wbuf unless stream_overflow

          when :settings
            _, settings = cmd
            old_initial_window_size = @peer_settings.initial_window_size
            settings.each do |ident, value|
              @peer_settings[ident] = value if ident < @peer_settings.length
            end

            new_initial_window_size = @peer_settings.initial_window_size
            if new_initial_window_size != old_initial_window_size
              delta = new_initial_window_size - old_initial_window_size
              overflow = false
              # grpc: snapshot, app threads may add streams concurrently.
              @streams.values.each do |stream|
                next if stream.idle? || stream.closed?
                stream.window_size += delta
                if stream.window_size > 0x7FFF_FFFF
                  write_goaway_frame wbuf, 0x3
                  overflow = true
                  break
                end
              end
              break if overflow
            end
            flush_pending wbuf

          when :send_window_update
            _, stream_id, connection_increment, stream_increment = cmd
            # grpc: the two windows are returned in one command, and each is
            # only written when it actually owes the peer something.
            if connection_increment.positive?
              write_frame_header wbuf, 4, 0x8, 0, 0
              write_uint32 wbuf, connection_increment
            end
            if stream_increment.positive?
              write_frame_header wbuf, 4, 0x8, 0, stream_id
              write_uint32 wbuf, stream_increment
            end

          when :close_stream
            _, stream = cmd
            @active_bodies.delete(stream.id)
            if stream.body
              @pending_body_size -= stream.body.bytesize
              stream.body.close
              stream.body = nil
            end

          when :shutdown
            break
          end

          # Flush a large buffer straight away; the drained case is handled at
          # the top of the loop, where +next+ cannot skip it.
          if wbuf.bytesize >= WRITE_BUFFER_SIZE
            io.write wbuf
            wbuf.clear
          end
        end
      rescue IOError, EOFError, SystemCallError, OpenSSL::OpenSSLError
        # Connection closed, exit write loop
      ensure
        io.write wbuf rescue nil if wbuf.bytesize > 0
        io.close rescue nil
        # grpc: release anybody blocked waiting for a chunk we will never send.
        @streams.each_value { |stream| stream.body&.close }
        drain_write_queue
      end

      # grpc: fires the acknowledgements of commands that never got written.
      def drain_write_queue
        until @write_queue.empty?
          cmd = @write_queue.pop(true)
          cmd[4]&.ack_write(cmd[5]) if cmd[0] == :grpc_data
        end
      rescue ThreadError
        nil
      end

      # grpc: returns the stream's body queue, creating it on first use, and
      # records the stream as having work for flush_pending.
      def body_for stream
        @active_bodies[stream.id] = stream
        stream.body ||= Body::Queue.new
      end

      # grpc: rewritten so that a body queue can stay open across writes and so
      # that the stream can be terminated either by END_STREAM on the last DATA
      # frame or by a trailing HEADERS block.
      #
      # Only streams that actually have something queued are visited. Walking
      # @streams.values built an Array of every live stream on the connection
      # for each flush, which made writing one message cost time proportional
      # to the number of open streams.
      def flush_pending wbuf
        return if @active_bodies.empty?
        @active_bodies.delete_if { |_id, stream| flush_stream wbuf, stream }
      end

      # Writes what it can of one stream's queued body. Returns true once the
      # stream has nothing left to write, so the caller can stop tracking it.
      def flush_stream wbuf, stream
        while (body = stream.body) && !body.terminated?
          if body.empty?
            break unless body.ended?
            write_body_terminator wbuf, stream, body
            break
          end

          max_frame = @peer_settings.max_frame_size
          send_size = [body.bytesize, max_frame, stream.window_size,
                       @connection_window].min

          if send_size <= 0
            if @pending_body_size > MAX_PENDING_BODY_SIZE
              write_frame_header wbuf, 4, 0x3, 0, stream.id
              write_uint32 wbuf, 0x7
              @pending_body_size -= body.bytesize
              body.close
              body.terminate!
              stream.body = nil
              stream.close!
              @streams.delete(stream.id)
              @open_stream_count -= 1
            end
            break
          end

          # grpc: send_size is already clamped to the queued bytes, so the
          # frame is exactly that long. Writing the header first and letting
          # the body append into the same buffer avoids allocating the chunk
          # and copying it twice.
          write_frame_header wbuf, send_size, 0x0, 0x00, stream.id
          header_end = wbuf.bytesize
          written = body.read_into wbuf, send_size

          # send_size is clamped to the queued bytes, so this normally matches.
          # A File part can still come up short if the file shrank, and a frame
          # header that overstated its payload would desynchronise the peer.
          if written != send_size
            wbuf.setbyte(header_end - 9, written >> 16)
            wbuf.setbyte(header_end - 8, (written >> 8) & 0xFF)
            wbuf.setbyte(header_end - 7, written & 0xFF)
          end

          is_last = body.empty? && body.ended? && body.trailers.nil?
          # END_STREAM is only known after the read, and the flags byte sits
          # five bytes back from the end of the header.
          wbuf.setbyte(header_end - 5, 0x01) if is_last

          stream.window_size -= written
          @connection_window -= written
          @pending_body_size -= written

          close_local_stream stream, body if is_last
        end

        body = stream.body
        body.nil? || body.terminated?
      end

      # grpc: emits the frame that carries END_STREAM once the queue drained.
      def write_body_terminator wbuf, stream, body
        if (trailers = body.trailers)
          hpack = @encoding_table.encode trailers
          write_frame_header wbuf, hpack.bytesize, 0x1, 0x04 | 0x01, stream.id
          wbuf << hpack
        else
          write_frame_header wbuf, 0, 0x0, 0x01, stream.id
        end
        close_local_stream stream, body
      end

      def close_local_stream stream, body
        body.close
        body.terminate!
        stream.body = nil
        stream.half_close_local!
        return unless stream.closed?
        @streams.delete(stream.id)
        @open_stream_count -= 1
      end

      # ── Read thread ───────────────────────────────────────────────────────

      def start_read_thread
        @reader = Thread.new {
          Thread.current.name = "reader - " + @name
          read_loop(FrameReader.new(@io))
        }
      end

      # grpc: +io+ is a FrameReader, which decodes each frame header in place
      # instead of allocating a String and an unpack Array per frame.
      def read_loop io
        while true
          begin
            break unless io.next_frame
          rescue IOError, EOFError, SystemCallError, OpenSSL::OpenSSLError
            break
          end
          len = io.length
          type = io.type
          flags = io.flags
          stream_ident = io.stream_id

          begin
            # grpc: the limit is the frame size this endpoint accepts, and it
            # applies to every frame type. SETTINGS used to be exempt, which
            # let a peer hand the read thread an arbitrarily long frame to
            # parse; RFC 7540 4.2 gives it no such exemption.
            if len > Frames::Settings::MAX_INBOUND_FRAME_SIZE
              raise Errors::FrameSizeError.new("Frame too large", 0)
            end

            # If we're expecting CONTINUATION, only CONTINUATION is allowed
            if @expecting_continuation && type != 0x9
              raise Errors::ProtocolError.new("Expected CONTINUATION", 0)
            end

            case type
            when 0x0 then handle_data io, len, flags, stream_ident
            when 0x1 then handle_headers io, len, flags, stream_ident
            when 0x2 then handle_priority io, len, flags, stream_ident
            when 0x3 then handle_rst_stream io, len, flags, stream_ident
            when 0x4 then handle_settings io, len, flags, stream_ident
            when 0x5 then handle_push_promise io, len, flags, stream_ident
            when 0x6 then handle_ping io, len, flags, stream_ident
            when 0x7
              handle_goaway io, len, flags, stream_ident
              break
            when 0x8 then handle_window_update io, len, flags, stream_ident
            when 0x9 then handle_continuation io, len, flags, stream_ident
            else
              io.skip(len) if len > 0 # skip unknown frame types (RFC 7540 4.1)
            end
          rescue Errors::StreamError => e
            io.skip(e.remaining) if e.remaining > 0
            # grpc: the stream is being reset, but a DATA frame thrown away
            # here has still spent connection window. Only DATA is flow
            # controlled, so crediting any other frame type would inflate the
            # window instead of restoring it.
            credit_connection_window(e.remaining) if type == 0x0
            @write_queue << [:rst_stream, e.stream_id, e.error_code]
            @highest_stream_id = e.stream_id if e.stream_id > @highest_stream_id
          rescue Errors::ConnectionError => e
            io.skip(e.remaining) if e.remaining > 0
            @write_queue << [:goaway, e.error_code]
            @write_queue << [:shutdown]
            break
          rescue IOError, EOFError, SystemCallError, OpenSSL::OpenSSLError
            break
          end
        end
      ensure
        @write_queue << [:shutdown]
        @handler.on_close
      end

      # ── Frame writers (called only from write thread) ─────────────────────

      def send_goaway_frame io, error
        io.write [(8 << 8) | 0x7, 0, 0, @highest_stream_id, error].pack("NCNNN")
      end

      # ── Frame handlers (called only from read thread) ─────────────────────

      def handle_data io, len, flags, stream_id
        # DATA frames cannot have stream_id = 0
        if stream_id.zero?
          raise Errors::ProtocolError.new("Got DATA on stream 0", len)
        end

        # grpc: a stream we reset locally may still have frames in flight;
        # discard them rather than failing the whole connection.
        if @locally_reset[stream_id]
          io.skip(len) if len > 0
          # The peer spent connection window on this frame even though it is
          # thrown away, so the window has to be given back.
          credit_connection_window len
          return
        end

        begin
          stream = @streams.fetch(stream_id)
        rescue KeyError
          if stream_id <= @highest_stream_id
            raise Errors::StreamClosedError.new("DATA on closed stream", len)
          else
            raise Errors::ProtocolError.new("Invalid stream", len)
          end
        end

        raise Errors::ProtocolError.new("Invalid stream", len) if stream.idle?

        # Check stream state - DATA not allowed on closed or half_closed_remote
        if stream.closed?
          raise Errors::StreamClosedError.new("DATA on closed stream", len)
        elsif stream.half_closed_remote?
          raise Errors::StreamClosed.new("DATA on half-closed-remote stream", stream_id, len)
        end

        # Check for PADDED flag (bit 3)
        if flags[3].zero?
          # No padding, read all data
          data_len = len
          pad_length = 0
        else
          # Padded frame must have at least 1 byte for pad length
          raise Errors::ProtocolError.new("Padded DATA with zero length", 0) if len == 0
          pad_length = io.readbyte

          # Validate pad length
          if pad_length >= len
            # Pad length is invalid (too large)
            raise Errors::ProtocolError.new("Invalid pad length", len - 1)
          end

          # Read data (excluding pad length byte and padding)
          data_len = len - pad_length - 1
        end

        if data_len > 0
          chunk = io.read(data_len)
          stream.data_received += data_len
          @handler.on_data stream, chunk
        end

        # Read and discard padding
        io.skip(pad_length) if pad_length > 0

        # grpc: return flow control window in blocks. Acknowledging every DATA
        # frame cost a queue push, a writer wake and two WINDOW_UPDATE frames
        # per frame received; the peer only needs the window back before it
        # runs out, so this waits until half of it is spent.
        #
        # The debt is the whole frame payload, the Pad Length byte and the
        # padding included, as RFC 7540 6.9.1 requires. Counting only the
        # application bytes would strand the padding in the window for good,
        # and a frame that carried nothing but padding would return nothing.
        if len.positive?
          @connection_unacked += len
          stream.unacked += len
          # A stream the peer has just ended does not need its window back.
          ends_stream = flags.odd?
          if @connection_unacked >= WINDOW_UPDATE_THRESHOLD ||
             (!ends_stream && stream.unacked >= WINDOW_UPDATE_THRESHOLD)
            @write_queue << [:send_window_update, stream_id,
                             @connection_unacked,
                             ends_stream ? 0 : stream.unacked]
            @connection_unacked = 0
            stream.unacked = 0
          end
        end

        # If END_STREAM flag is set, half-close remote
        if flags.odd? # Bottom bit is set
          # Validate content-length if specified
          if stream.content_length
            if stream.data_received != stream.content_length
              raise Errors::StreamError.new("Content-length mismatch", stream_id)
            end
          end

          stream.half_close_remote!
          @handler.on_request stream
          if stream.closed?
            @streams.delete(stream_id)
            @open_stream_count -= 1
          end
        end
      end

      def handle_headers io, len, flags, stream_id
        # If already expecting CONTINUATION, receiving HEADERS is an error
        raise Errors::ProtocolError.new("Already expecting continuation", 0) if @expecting_continuation

        # Validate stream ID is non-zero
        raise Errors::ProtocolError.new("Got HEADERS on stream 0", len) if stream_id.zero?

        # grpc: see handle_data; tolerate late frames for locally reset streams.
        if @locally_reset[stream_id]
          io.skip(len) if len > 0
          return
        end

        # Validate stream ID parity for new streams (peer-initiated)
        unless @streams.key?(stream_id)
          if @server_mode && stream_id.even?
            raise Errors::ProtocolError.new("Even stream ID from client", len)
          elsif !@server_mode && stream_id.odd?
            raise Errors::ProtocolError.new("Odd stream ID from server", len)
          end

          # Validate stream ID is increasing (unless stream already exists)
          if stream_id <= @highest_stream_id
            raise Errors::ProtocolError.new("Stream ID not increasing", len)
          end

          # Check MAX_CONCURRENT_STREAMS limit for new streams
          if @open_stream_count >= @local_max_concurrent_streams
            raise Errors::RefusedStream.new("Max concurrent streams exceeded", stream_id, len)
          end
        end

        # Check stream state
        @streams[stream_id]&.receiving_headers!(flags.odd?, len)

        # Check for PRIORITY flag (bit 5) - HEADERS can include priority data
        has_priority = flags[5].positive?
        priority_bytes = has_priority ? 5 : 0

        payload_start = 0
        payload_len = 0

        # Check for PADDED flag (bit 3)
        if flags[3].zero?
          # No padding
          if len > 0
            payload = io.read(len)
            payload_len = len
          else
            payload = "".b
          end

          # If PRIORITY flag set, validate and extract priority data
          if has_priority
            if payload.bytesize < 5
              raise Errors::FrameSizeError.new("HEADERS priority too short", 0)
            end
            stream_dependency = payload.unpack1("N") & 0x7FFF_FFFF
            # Check for self-dependency
            if stream_dependency == stream_id
              raise Errors::StreamError.new("HEADERS self-dependency", stream_id)
            end

            # Remove priority data from payload
            payload_start = 5
            payload_len -= 5
          end
        else
          # Has padding
          return if len.zero?
          pad_length = io.readbyte

          # Validate pad length (must account for priority data if present)
          if pad_length >= len || (len - pad_length - 1) < priority_bytes
            raise Errors::ProtocolError.new("Invalid HEADERS pad length", len - 1)
          end

          # Read header block (excluding pad length byte, priority, and padding)
          data_len = len - pad_length - 1
          if data_len > 0
            payload = io.read(data_len)
            payload_len = data_len
          else
            payload = "".b
          end

          # If PRIORITY flag set, validate and extract priority data
          if has_priority && payload.bytesize >= 5
            stream_dependency = payload.unpack1("N") & 0x7FFF_FFFF
            # Check for self-dependency
            if stream_dependency == stream_id
              io.skip(pad_length) if pad_length > 0
              raise Errors::StreamError.new("HEADERS self-dependency", stream_id)
            end
            # Remove priority data from payload
            payload_start = 5
            payload_len -= 5
          end

          # Read and discard padding
          io.skip(pad_length) if pad_length > 0
        end

        # Check if END_HEADERS flag is set (bit 2)
        if flags[2].positive?
          # Update highest stream ID seen
          if stream_id > @highest_stream_id
            @highest_stream_id = stream_id
          end

          stream = @streams[stream_id] ||= build_stream(stream_id)

          # Complete header block in this frame
          headers = @decoding_table.decode payload, payload_start, payload_len, max_list_size: MAX_HEADER_LIST_SIZE

          # grpc: a second HEADERS block on a stream carries trailers; gRPC
          # needs them separately from the initial metadata.
          trailer = !!stream.headers
          stream.content_length = validate_headers headers, stream_id, trailer

          # Transition state: idle -> open
          if stream.idle?
            stream.open!
            @open_stream_count += 1
          end

          if trailer
            @handler.on_trailers stream, headers
          else
            stream.headers = headers
            @handler.on_headers stream
          end

          # If END_STREAM flag is set, half-close remote
          if flags.odd?
            # Validate content-length before closing
            if stream.content_length && stream.data_received
              if stream.data_received != stream.content_length
                raise Errors::StreamError.new("Content-length mismatch", stream_id)
              end
            end

            stream.half_close_remote!
            @handler.on_request stream
            if stream.closed?
              @streams.delete(stream_id)
              @open_stream_count -= 1
            end
          end
        else
          # Partial header block, expect CONTINUATION
          @expecting_continuation = true
          @continuation_stream_id = stream_id
          if payload_start > 0
            @header_buffer = payload.byteslice(payload_start, payload_len)
          else
            @header_buffer = payload
          end
          @continuation_flags = flags # Save flags from HEADERS frame

          # Update highest stream ID seen
          if stream_id > @highest_stream_id
            @highest_stream_id = stream_id
          end
        end
      end

      def handle_ping io, len, flags, stream_ident
        raise Errors::ProtocolError.new("PING on non-zero stream", len) unless stream_ident.zero?
        raise Errors::FrameSizeError.new("PING length != 8", len) unless len == 8

        if flags.even?
          # Peer PING: queue ACK for write thread. This payload has to be
          # echoed back, so it is the one PING body that must be copied.
          @write_queue << [:ping_ack, io.read(8)]
        else
          # ACK of our PING: compute RTT
          sent_at = io.read_uint64
          rtt_ns = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - sent_at
          @handler.on_ping rtt_ns
        end
      end

      def handle_settings io, len, flags, stream_ident
        raise Errors::ProtocolError.new("SETTINGS on non-zero stream", len) unless stream_ident.zero?

        # SETTINGS with ACK flag must have zero length (bit 0)
        if flags.odd?
          raise Errors::FrameSizeError.new("SETTINGS ACK with payload", len) if len.positive?
          return
        end

        raise Errors::FrameSizeError.new("SETTINGS length not multiple of 6", len) if (len % 6) != 0

        parsed = {}
        offset = 0

        io.each_setting(len / 6) do |ident, value|

          # Validate parameter values
          case ident
          when 0x2 # SETTINGS_ENABLE_PUSH
            unless value == 0 || value == 1
              raise Errors::ProtocolError.new("ENABLE_PUSH must be 0 or 1", len - offset - 6)
            end
          when 0x4 # SETTINGS_INITIAL_WINDOW_SIZE
            if value > 0x7FFF_FFFF
              raise Errors::FlowControlError.new("INITIAL_WINDOW_SIZE too large", len - offset - 6)
            end
          when 0x5 # SETTINGS_MAX_FRAME_SIZE
            if value < 16384 || value > 16777215
              raise Errors::ProtocolError.new("MAX_FRAME_SIZE out of range", len - offset - 6)
            end
          end

          parsed[ident] = value
          offset += 6
        end

        @write_queue << [:settings, parsed]
        @write_queue << [:settings_ack]
        # grpc: the peer's first SETTINGS frame is what makes a connection
        # usable, so gRPC waits for it before reporting a channel READY.
        @handler.on_settings parsed
      end

      def handle_goaway io, len, flags, stream_ident
        raise Errors::ProtocolError.new("GOAWAY on non-zero stream", len) unless stream_ident.zero?
        raise Errors::FrameSizeError.new("GOAWAY too short", len) if len < 8

        # Consume last_stream_id and error_code fields to advance the IO position
        io.skip(8)

        # Read optional debug data
        io.skip(len - 8) if len > 8
      end

      def handle_window_update io, len, flags, stream_ident
        raise Errors::FrameSizeError.new("WINDOW_UPDATE length != 4", len) unless len == 4

        increment = io.read_uint32 & 0x7FFF_FFFF

        # Increment must be non-zero
        if increment.zero?
          if stream_ident.zero?
            raise Errors::ProtocolError.new("WINDOW_UPDATE increment 0 on connection", 0)
          else
            raise Errors::StreamError.new("WINDOW_UPDATE increment 0 on stream", stream_ident)
          end
        end

        # Validate stream exists and is not idle (for stream-level updates)
        unless stream_ident.zero?
          stream = @streams[stream_ident]
          if !stream
            # grpc: @highest_stream_id only tracks peer-initiated streams, so
            # it says nothing about a stream we opened and already finished.
            # RFC 7540 5.1 requires WINDOW_UPDATE for such a stream to be
            # ignored, not treated as a connection error.
            if stream_ident <= @highest_stream_id || closed_locally?(stream_ident)
              return # Stream already closed, ignore
            else
              raise Errors::ProtocolError.new("WINDOW_UPDATE on idle stream", 0)
            end
          elsif stream.idle?
            raise Errors::ProtocolError.new("WINDOW_UPDATE on idle stream", 0)
          end
        end

        @write_queue << [:window_update, stream_ident, increment]
      end

      def handle_rst_stream io, len, flags, stream_id
        raise Errors::ProtocolError.new("RST_STREAM on stream 0", len) if stream_id.zero?
        raise Errors::FrameSizeError.new("RST_STREAM length != 4", len) if len != 4

        # Consume error_code to advance the IO position
        error_code = io.read_uint32

        # Validate stream state - RST_STREAM on idle stream is PROTOCOL_ERROR
        stream = @streams[stream_id]
        if !stream
          if stream_id <= @highest_stream_id || closed_locally?(stream_id)
            return # Stream already closed, ignore per RFC
          else
            raise Errors::ProtocolError.new("RST_STREAM on idle stream", 0)
          end
        elsif stream.idle?
          raise Errors::ProtocolError.new("RST_STREAM on idle stream", 0)
        end

        # Close the stream and mark that RST_STREAM was received
        stream.rst_received = true
        stream.close!
        @streams.delete(stream_id)
        @open_stream_count -= 1
        @write_queue << [:close_stream, stream]
        # grpc: an RPC blocked on this stream has to learn that it died.
        @handler.on_stream_error stream, error_code
      end

      # grpc: true when +stream_id+ names a stream this endpoint opened and
      # has since finished with.
      def closed_locally? stream_id
        locally_initiated = @server_mode ? stream_id.even? : stream_id.odd?
        locally_initiated && stream_id < @next_stream_id
      end

      def handle_priority io, len, flags, stream_id
        raise Errors::ProtocolError.new("PRIORITY on stream 0", len) if stream_id.zero?
        raise Errors::FrameSizeError.new("PRIORITY length != 5", len) if len != 5

        # Read priority data
        data = io.read(5)
        stream_dependency = data.unpack1("N") & 0x7FFF_FFFF
        # exclusive = (data.unpack1("N") & 0x8000_0000) != 0
        # weight = data[4].unpack1("C")

        # Check for self-dependency
        if stream_dependency == stream_id
          raise Errors::StreamError.new("PRIORITY self-dependency", stream_id)
        end
      end

      def handle_push_promise io, len, flags, stream_id
        raise Errors::ProtocolError.new("PUSH_PROMISE not allowed", len)
      end

      def handle_continuation io, len, flags, stream_id
        raise Errors::ProtocolError.new("Unexpected CONTINUATION", len) unless @expecting_continuation
        raise Errors::ProtocolError.new("CONTINUATION stream mismatch", len) if stream_id != @continuation_stream_id
        raise Errors::ProtocolError.new("CONTINUATION on stream 0", len) if stream_id.zero?

        payload = io.read(len)
        return unless payload

        # Append to header buffer
        @header_buffer << payload

        if @header_buffer.bytesize > MAX_HEADER_LIST_SIZE
          @expecting_continuation = false
          @header_buffer = nil
          @continuation_stream_id = nil
          @continuation_flags = nil
          raise Errors::ConnectionError.new("Header block too large", 0, 0x0B) # ENHANCE_YOUR_CALM
        end

        # Check if END_HEADERS flag is set (bit 2)
        if flags[2].positive?
          # Complete header block
          @expecting_continuation = false
          complete_payload = @header_buffer
          saved_flags = @continuation_flags # Use flags from original HEADERS frame
          @header_buffer = nil
          @continuation_stream_id = nil
          @continuation_flags = nil

          stream = @streams[stream_id] ||= build_stream(stream_id)

          headers = @decoding_table.decode complete_payload, 0, complete_payload.bytesize, max_list_size: MAX_HEADER_LIST_SIZE

          # grpc: see handle_headers; trailers get their own callback.
          trailer = !!stream.headers
          stream.content_length = validate_headers headers, stream_id, trailer

          # Transition state: idle -> open
          if stream.idle?
            stream.open!
            @open_stream_count += 1
          end

          if trailer
            @handler.on_trailers stream, headers
          else
            stream.headers = headers
            @handler.on_headers stream
          end

          # If END_STREAM flag was set on original HEADERS frame, half-close remote
          if saved_flags.odd?
            stream.half_close_remote!
            @handler.on_request stream
            if stream.closed?
              @streams.delete(stream_id)
              @open_stream_count -= 1
            end
          end
        end
        # Otherwise, keep expecting more CONTINUATION frames
      end
    end
  end
end
    end
  end
end
