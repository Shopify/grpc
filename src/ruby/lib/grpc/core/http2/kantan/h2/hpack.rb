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
require_relative "../huffman"
require_relative "../errors"

module Kantan
  module H2
    # grpc: Ruby 4.1 introduced the "R" pack directive (LEB128 varint) and the
    # "^" unpack modifier that also yields the new offset. gRPC supports Ruby
    # 3.2 and up, so the HPACK integer continuation octets are coded by hand.
    module Varint # :nodoc:
      module_function

      def read buffer, pos
        value = 0
        shift = 0
        loop do
          byte = buffer.getbyte(pos)
          raise Errors::CompressionError, "truncated integer" unless byte
          pos += 1
          value |= (byte & 0x7F) << shift
          break if byte < 0x80
          shift += 7
          raise Errors::CompressionError, "integer too large" if shift > 56
        end
        [value, pos]
      end

      # grpc: appends bytes rather than one-byte Strings from Integer#chr.
      def write out, value
        while value >= 0x80
          out << ((value & 0x7F) | 0x80)
          value >>= 7
        end
        out << value
        out
      end
    end

    class HPACK
      class DynamicTable # :nodoc:
        def initialize max_size
          @entries = []
          @seqs = []
          @size = 0
          @max_size = max_size
          @seq = 0
          @full_index = {}
          @name_index = {}
        end

        def add name, value
          @entries.unshift([name, value])
          @seqs.unshift(@seq)
          (@full_index[name] ||= {})[value] = @seq
          @name_index[name] = @seq
          @seq += 1
          @size += name.bytesize + value.bytesize + 32
          evict
        end

        def find name, value
          seq_num = @full_index.dig(name, value)
          return unless seq_num
          62 + (@seq - 1 - seq_num)
        end

        def find_name name
          seq_num = @name_index[name]
          return unless seq_num
          62 + (@seq - 1 - seq_num)
        end

        def lookup idx
          @entries.fetch(idx - 62)
        rescue IndexError
          raise Errors::CompressionError, "invalid dynamic table index #{idx}"
        end

        def resize new_max
          @max_size = new_max
          evict
        end

        private

        def evict
          while @size > @max_size && !@entries.empty?
            evicted_name, evicted_value = @entries.pop
            evicted_seq = @seqs.pop
            @size -= evicted_name.bytesize + evicted_value.bytesize + 32
            if (inner = @full_index[evicted_name]) && inner[evicted_value] == evicted_seq
              inner.delete(evicted_value)
              @full_index.delete(evicted_name) if inner.empty?
            end
            @name_index.delete(evicted_name) if @name_index[evicted_name] == evicted_seq
          end
        end
      end

      # Static table as defined in RFC 7541
      STATIC_TABLE = Ractor.make_shareable([
        [":authority", ""],
        [":method", "GET"],
        [":method", "POST"],
        [":path", "/"],
        [":path", "/index.html"],
        [":scheme", "http"],
        [":scheme", "https"],
        [":status", "200"],
        [":status", "204"],
        [":status", "206"],
        [":status", "304"],
        [":status", "400"],
        [":status", "404"],
        [":status", "500"],
        ["accept-charset", ""],
        ["accept-encoding", "gzip, deflate"],
        ["accept-language", ""],
        ["accept-ranges", ""],
        ["accept", ""],
        ["access-control-allow-origin", ""],
        ["age", ""],
        ["allow", ""],
        ["authorization", ""],
        ["cache-control", ""],
        ["content-disposition", ""],
        ["content-encoding", ""],
        ["content-language", ""],
        ["content-length", ""],
        ["content-location", ""],
        ["content-range", ""],
        ["content-type", ""],
        ["cookie", ""],
        ["date", ""],
        ["etag", ""],
        ["expect", ""],
        ["expires", ""],
        ["from", ""],
        ["host", ""],
        ["if-match", ""],
        ["if-modified-since", ""],
        ["if-none-match", ""],
        ["if-range", ""],
        ["if-unmodified-since", ""],
        ["last-modified", ""],
        ["link", ""],
        ["location", ""],
        ["max-forwards", ""],
        ["proxy-authenticate", ""],
        ["proxy-authorization", ""],
        ["range", ""],
        ["referer", ""],
        ["refresh", ""],
        ["retry-after", ""],
        ["server", ""],
        ["set-cookie", ""],
        ["strict-transport-security", ""],
        ["transfer-encoding", ""],
        ["user-agent", ""],
        ["vary", ""],
        ["via", ""],
        ["www-authenticate", ""]
      ])

      def initialize table_size = 4096
        @dynamic_table = DynamicTable.new(table_size)
        @max_table_size = table_size
      end

      def encode headers
        out = "".b
        headers.each do |name, value|
          idx = key_value_index(name, value)
          if idx
            encode_integer(out, idx, 7, 0x80)
            next
          end

          # Name match — prefer static table (smaller indices)
          name_idx = key_index(name)

          case name
            # Headers whose values change frequently — don't add to dynamic table
          when ":path", "content-length", "etag", "location", "set-cookie"
            # Literal without indexing
            if name_idx
              encode_integer(out, name_idx, 4, 0x00)
            else
              out << 0x00
              encode_string(out, name)
            end
            encode_string(out, value)
          else
            # Literal with incremental indexing
            if name_idx
              encode_integer(out, name_idx, 6, 0x40)
            else
              out << 0x40
              encode_string(out, name)
            end
            encode_string(out, value)
            @dynamic_table.add(name, value)
          end
        end
        out
      end

      def decode buffer, pos = 0, final = buffer.bytesize, max_list_size: nil
        headers = []
        list_size = 0
        seen_header = false

        while pos < final
          byte = buffer.getbyte(pos)
          pos += 1
          if byte > 0x7F # Bit 8 is set
            seen_header = true
            idx = byte & 0x7F
            if idx == 127
              remainder, pos = Varint.read(buffer, pos)
              idx = 127 + remainder
            end
            entry = lookup(idx)
            if max_list_size
              list_size += entry[0].bytesize + entry[1].bytesize + 32
              raise Errors::CompressionError, "header list too large" if list_size > max_list_size
            end
            headers << entry
          elsif byte > 0x3F # Bit 7 is set
            seen_header = true
            name_idx = byte & 0x3F
            if name_idx == 63
              remainder, pos = Varint.read(buffer, pos)
              name_idx = 63 + remainder
            end

            if name_idx.zero?
              len = buffer.getbyte(pos) || raise(Errors::CompressionError, "truncated header block")
              huffman = len > 0x7F # Bit 8 is set
              len &= 0x7F
              pos += 1
              if len == 127
                remainder, pos = Varint.read(buffer, pos)
                len = 127 + remainder
              end
              name = decode_name(huffman, buffer, pos, len)
              pos += len
            else
              name = lookup(name_idx).first
            end

            len = buffer.getbyte(pos) || raise(Errors::CompressionError, "truncated header block")
            huffman = len > 0x7F # Bit 8 is set
            len &= 0x7F
            pos += 1
            if len == 127
              remainder, pos = Varint.read(buffer, pos)
              len = 127 + remainder
            end
            value = decode_value huffman, buffer, pos, len
            pos += len

            if max_list_size
              list_size += name.bytesize + value.bytesize + 32
              raise Errors::CompressionError, "header list too large" if list_size > max_list_size
            end
            headers << [name, value]
            @dynamic_table.add(name, value)
          elsif byte > 0x1F # Bit 5 is set: Dynamic table size update
            raise Errors::CompressionError, "table size update after headers" if seen_header
            new_size = byte & 0x1F
            if new_size == 31
              remainder, pos = Varint.read(buffer, pos)
              new_size = 31 + remainder
            end
            raise Errors::CompressionError, "table size exceeds SETTINGS" if new_size > @max_table_size
            @dynamic_table.resize(new_size)
          else
            seen_header = true
            name_idx = byte & 0x0F
            if name_idx == 15
              remainder, pos = Varint.read(buffer, pos)
              name_idx = 15 + remainder
            end

            if name_idx.zero?
              len = buffer.getbyte(pos) || raise(Errors::CompressionError, "truncated header block")
              huffman = len > 0x7F
              len &= 0x7F
              pos += 1
              if len == 127
                remainder, pos = Varint.read(buffer, pos)
                len = 127 + remainder
              end
              name = decode_name(huffman, buffer, pos, len)
              pos += len
            else
              name = lookup(name_idx).first
            end

            len = buffer.getbyte(pos) || raise(Errors::CompressionError, "truncated header block")
            huffman = len > 0x7F
            len &= 0x7F
            pos += 1
            if len == 127
              remainder, pos = Varint.read(buffer, pos)
              len = 127 + remainder
            end
            value = decode_value huffman, buffer, pos, len
            pos += len

            if max_list_size
              list_size += name.bytesize + value.bytesize + 32
              raise Errors::CompressionError, "header list too large" if list_size > max_list_size
            end
            headers << [name, value]
          end
        end

        headers
      end

      private

      m = STATIC_TABLE.each_with_object({}).with_index do |((k, v), o), i|
        (o[k] ||= {})[v] = i
      end

      kv_code = "case key\n" + m.map { |key, values|
        "when #{key.dump}" +
        if values.length == 1
          " then value == #{values.keys.first.dump} ? #{values.values.first + 1} : nil"
        else
          "\n  case value\n" +
            values.map { |v, n| "  when #{v.dump} then #{n + 1}" }.join("\n") +
            "\n  else\n    nil\n  end"
        end
      }.join("\n") + "\nelse\nend"

      class_eval "def static_key_value_index key, value\n#{kv_code}\nend", __FILE__, __LINE__

      key_code = "case key\n" + m.map { |key, values|
        "when #{key.dump} then #{values.values.first + 1}"
      }.join("\n") + "\nelse\nend"

      class_eval "def static_key_index key\n#{key_code}\nend", __FILE__, __LINE__

      def key_value_index key, value
        static_key_value_index(key, value) || @dynamic_table.find(key, value)
      end

      def key_index key
        static_key_index(key) || @dynamic_table.find_name(key)
      end

      def lookup idx
        if idx < 62 # STATIC_TABLE.length + 1
          raise Errors::CompressionError, "index 0 is invalid" if idx.zero?
          STATIC_TABLE[idx - 1]
        else
          @dynamic_table.lookup(idx)
        end
      end

      def decode_name huffman, buffer, pos, len
        if huffman
          Huffman.decode_name(buffer, pos, len)
        else
          name = buffer.byteslice(pos, len)
          raise Errors::CompressionError, "Uppercase in header name" if name.match?(/[A-Z]/)
          name
        end
      end

      def decode_value huffman, buffer, pos, len
        if huffman
          Huffman.decode(buffer, pos, len)
        else
          buffer.byteslice(pos, len)
        end
      end

      # grpc: +out << byte+ appends one byte to a binary String, and unlike
      # [byte].pack("C", buffer: out) it does not allocate the pair Array.
      def encode_integer out, value, prefix_bits, pattern
        max = (1 << prefix_bits) - 1
        if value < max
          out << (pattern | value)
        else
          out << (pattern | max)
          Varint.write(out, value - max)
        end
      end

      def encode_string out, str
        # grpc: measure the Huffman form before producing it. The literal wins
        # often enough that encoding first and discarding the result was pure
        # waste, and measuring costs about 40 per cent of an encode.
        size = Huffman.encoded_bytesize(str)
        if size < str.bytesize
          if size < 127
            out << (0x80 | size)
          else
            out << 0xFF
            Varint.write(out, size - 127)
          end
          out << Huffman.encode(str)
        else
          len = str.bytesize
          if len < 127
            out << len
          else
            out << 0x7F
            Varint.write(out, len - 127)
          end
          out << str
        end
      end
    end
  end
end
    end
  end
end
