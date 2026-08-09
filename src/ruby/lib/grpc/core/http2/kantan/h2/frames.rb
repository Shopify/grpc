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
    module Frames
      NAMES = [
        :DATA,
        :HEADERS,
        :PRIORITY,
        :RST_STREAM,
        :SETTINGS,
        :PUSH_PROMISE,
        :PING,
        :GOAWAY,
        :WINDOW_UPDATE,
        :CONTINUATION,
      ]

      NAMES.each_with_index { next unless _1; const_set(_1, _2) }

      class Settings < Struct.new(:nil, :header_table_size, :enable_push, :max_concurrent_streams,
        :initial_window_size, :max_frame_size, :max_header_list_size)
        NAMES = [
          nil,
          :HEADER_TABLE_SIZE,
          :ENABLE_PUSH,
          :MAX_CONCURRENT_STREAMS,
          :INITIAL_WINDOW_SIZE,
          :MAX_FRAME_SIZE,
          :MAX_HEADER_LIST_SIZE,
        ].freeze

        NAMES.each_with_index { next unless _1; const_set(_1, _2) }

        DEFAULT = self.new(
          nil,
          nil, # default is 4096
          nil, # don't specify push promise
          100, # max concurrent streams
        ).freeze

        def self.encode stream_id, settings
          settings = settings.each_with_index.select { |v, _| v }
          bytesize = settings.length * 6
          type = 0x4

          [
            (bytesize << 8) | type,
            0,
            stream_id
          ].pack("NCN") + settings.map { |val, i|
            [i, val].pack("nN")
          }.join
        end

        def encode stream_id
          self.class.encode stream_id, self
        end

        DEFAULT_ENCODED = DEFAULT.encode(0).freeze
      end
    end
  end
end
    end
  end
end
