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
  class Handler
    def on_headers stream; end
    # grpc: called instead of #on_data, with the frame reader positioned on
    # +len+ buffered payload bytes. Handlers that want the payload as a String
    # get one here; those that are going to append it somewhere override this
    # and take the bytes without a copy.
    def on_data stream, chunk; end

    def on_data_into stream, reader, len
      on_data(stream, reader.read(len))
    end
    def on_request stream; end
    # grpc: trailing HEADERS blocks and peer RST_STREAM both need to reach the
    # RPC that is blocked on the stream.
    def on_trailers stream, headers; end
    def on_stream_error stream, error_code; end
    def on_settings settings; end
    def on_ping rtt; end
    def on_close; end
  end
end
    end
  end
end
