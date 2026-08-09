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

        # grpc: these are this endpoint's own policy. They are deliberately not
        # called INITIAL_WINDOW_SIZE or MAX_FRAME_SIZE, because NAMES above
        # already binds those to the setting identifiers 4 and 5.
        #
        # The HTTP/2 default window is 65535 bytes, so a peer sending
        # 64 KiB messages has to stop and wait for a WINDOW_UPDATE on every
        # one of them. gRPC moves messages of that size routinely, so this
        # advertises a window big enough to keep them flowing. The connection
        # window is raised to match in Session, and it is what bounds how much
        # unread data a connection can hold.
        ADVERTISED_INITIAL_WINDOW_SIZE = 1 << 20

        # grpc: the largest frame this endpoint accepts. This is the protocol
        # default, so it is not advertised; naming it keeps Session's inbound
        # check and what a peer assumes about us in step.
        #
        # Raising it and advertising it was measured, and bought about 7 per
        # cent on 64 KiB messages between two pure Ruby peers, and nothing at
        # all against a C peer, which keeps sending 16 KiB frames. It also
        # fails h2spec 4.2.3, which sizes its oversized HEADERS frame against
        # the default rather than against the advertised value. Not worth it.
        MAX_INBOUND_FRAME_SIZE = 16_384

        DEFAULT = self.new(
          nil,
          nil, # default is 4096
          nil, # don't specify push promise
          100, # max concurrent streams
          ADVERTISED_INITIAL_WINDOW_SIZE,
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
