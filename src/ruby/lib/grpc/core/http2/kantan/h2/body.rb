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
module Kantan
  module H2
    module Body
      # grpc: appends the bytes of +str+ to a binary buffer whatever its
      # encoding. String#b would copy the whole payload first.
      if String.method_defined?(:append_as_bytes)
        def self.append_bytes buf, str
          buf.append_as_bytes(str)
        end
      else
        def self.append_bytes buf, str
          buf << (str.encoding == Encoding::BINARY ? str : str.b)
        end
      end

      # grpc: appends bytes [+offset+, +len+) of +str+ to a binary buffer,
      # without cutting a String out of it first. The five argument form of
      # String#bytesplice copies straight from one buffer into the other, so
      # framing a large message no longer allocates a slice per DATA frame
      # and copies it twice.
      #
      # It carries the same encoding rule as String#<<, so it is only used
      # when the source is already binary, which every frame this library
      # builds is. Anything else falls back to the slice.
      BYTESPLICE_APPENDS =
        begin
          probe = String.new(encoding: Encoding::BINARY)
          probe.bytesplice(0, 0, 'ab'.b, 0, 1)
          probe == 'a'.b
        rescue StandardError, ArgumentError
          false
        end

      if BYTESPLICE_APPENDS
        def self.append_slice buf, str, offset, len
          if str.encoding == Encoding::BINARY
            buf.bytesplice(buf.bytesize, 0, str, offset, len)
          else
            append_bytes(buf, str.byteslice(offset, len))
          end
        end
      else
        def self.append_slice buf, str, offset, len
          append_bytes(buf, str.byteslice(offset, len))
        end
      end

      class Buffer
        def initialize string
          @string = string
          @offset = 0
        end

        def read n
          chunk = @string.byteslice(@offset, n)
          @offset += n
          chunk
        end

        # grpc: appends up to +n+ bytes straight to +buf+ and returns how many.
        # Framing a chunk used to allocate it here and copy it into the write
        # buffer immediately afterwards.
        #
        # Both paths go through Body.append_bytes. A payload arrives in
        # whatever encoding the caller had, and a plain +buf << slice+ of a
        # UTF-8 payload is not encoding safe: against an all-ASCII buffer it
        # silently retags the buffer as UTF-8, and against a buffer that
        # already holds a frame header with a high byte in it -- the normal
        # case -- it raises Encoding::CompatibilityError and takes the
        # connection down. A partial read can also split a codepoint, so the
        # slice need not be valid text at all.
        def read_into buf, n
          available = @string.bytesize - @offset
          n = available if n > available
          if @offset.zero? && n == @string.bytesize
            # The whole part at once, which is every message that fits in a
            # frame. Appending it directly saves slicing a copy first.
            Body.append_bytes(buf, @string)
          else
            Body.append_slice(buf, @string, @offset, n)
          end
          @offset += n
          n
        end

        def bytesize
          @string.bytesize - @offset
        end

        def empty?
          @offset >= @string.bytesize
        end

        def close
        end
      end

      # grpc: an outbound body that accepts chunks over the lifetime of a
      # stream instead of being fully known up front, and that carries the
      # optional trailing HEADERS block gRPC sends after the last DATA frame.
      #
      # The stream is only half-closed once #end! has been called AND every
      # queued byte has been flushed.
      class Queue
        attr_reader :trailers

        def initialize
          @parts = []
          @size = 0
          @ended = false
          @trailers = nil
          @terminated = false
        end

        # +ack_to+, when given, is told once every byte of +part+ has been
        # taken out of this queue and into the transport's write buffer, which
        # is how gRPC applies write backpressure. That is one step short of
        # the socket, and it is the right point: the bytes are no longer this
        # queue's to hold.
        #
        # A receiver and a size rather than a closure. The entry this pushes
        # has to be allocated either way, so carrying the two values in it
        # costs nothing, where a lambda per message did not.
        def push_part part, ack_to = nil, ack_size = 0
          @parts << [part, ack_to, ack_size, 0]
          @size += part.bytesize
        end

        # A String is held directly, with its read offset in the entry, rather
        # than wrapped in a Buffer. The entry has to exist either way, so the
        # offset rides along for nothing, where the wrapper was an object per
        # message. Other part kinds, such as Body::File, still answer
        # #read_into themselves.
        def push_data string, ack_to = nil, ack_size = 0
          if string.empty?
            ack_to&.ack_write(ack_size)
          else
            @parts << [string, ack_to, ack_size, 0]
            @size += string.bytesize
          end
        end

        # Marks the end of the outbound stream. +trailers+, when given, is
        # written as a HEADERS frame with END_STREAM once the data drains.
        def end! trailers = nil
          @ended = true
          @trailers = trailers
        end

        def ended?
          @ended
        end

        # True once the terminal frame has been written.
        def terminated?
          @terminated
        end

        def terminate!
          @terminated = true
        end

        def read n
          out = +''.b
          read_into out, n
          out
        end

        # grpc: appends up to +n+ bytes of the queue to +buf+ and returns how
        # many were appended.
        def read_into buf, n
          taken = 0
          while taken < n && (entry = @parts.first)
            part = entry[0]
            if part.is_a?(String)
              taken += take_string(entry, buf, n - taken)
              next unless entry[3] >= part.bytesize
            else
              taken += part.read_into(buf, n - taken)
              next unless part.empty?
              part.close
            end
            @parts.shift
            entry[1]&.ack_write(entry[2])
          end
          @size -= taken
          taken
        end

        # Appends up to +want+ bytes of the entry's String, from where the
        # last call left off, and records the new offset in the entry.
        def take_string entry, buf, want
          string = entry[0]
          offset = entry[3]
          available = string.bytesize - offset
          want = available if want > available
          if offset.zero? && want == string.bytesize
            Body.append_bytes(buf, string)
          else
            Body.append_slice(buf, string, offset, want)
          end
          entry[3] = offset + want
          want
        end

        def bytesize
          @size
        end

        def empty?
          @size.zero?
        end

        def close
          @parts.each do |part, ack_to, ack_size, _offset|
            part.close unless part.is_a?(String)
            ack_to&.ack_write(ack_size)
          end
          @parts.clear
          @size = 0
        end
      end

      class File
        def initialize path
          @io = ::File.open(path, "rb")
          @remaining = @io.size
        end

        def read n
          chunk = @io.read(n)
          @remaining -= chunk.bytesize
          chunk
        end

        # grpc: see Buffer#read_into. A file still needs one read buffer, but
        # it is reused across calls instead of allocated per frame.
        def read_into buf, n
          @scratch ||= String.new(encoding: Encoding::BINARY, capacity: n)
          chunk = @io.read(n, @scratch)
          return 0 if chunk.nil?
          buf << chunk
          @remaining -= chunk.bytesize
          chunk.bytesize
        end

        def bytesize
          @remaining
        end

        def empty?
          @remaining == 0
        end

        def close
          @io.close
        end
      end
    end
  end
end
    end
  end
end
