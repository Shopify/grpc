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

        # +ack+, when given, is called once every byte of +part+ has been
        # handed to the socket, which is how gRPC applies write backpressure.
        def push_part part, ack = nil
          @parts << [part, ack]
          @size += part.bytesize
        end

        def push_data string, ack = nil
          if string.empty?
            ack&.call
          else
            push_part Buffer.new(string), ack
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
          while out.bytesize < n && (entry = @parts.first)
            part, ack = entry
            out << part.read(n - out.bytesize)
            next unless part.empty?
            part.close
            @parts.shift
            ack&.call
          end
          @size -= out.bytesize
          out
        end

        def bytesize
          @size
        end

        def empty?
          @size.zero?
        end

        def close
          @parts.each do |part, ack|
            part.close
            ack&.call
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
