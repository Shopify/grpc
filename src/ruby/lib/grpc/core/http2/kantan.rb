

# Vendored from kantan (https://github.com/tenderlove/kantan), Copyright
# Aaron Patterson, distributed under the Apache License 2.0 -- the same
# licence as gRPC. The code is namespaced under GRPC::Core::Http2 so that it
# cannot collide with a separately installed kantan gem.
#
# Local modifications are marked with "grpc:" comments.

require_relative "kantan/errors"
require_relative "kantan/huffman"
require_relative "kantan/stream"
require_relative "kantan/handler"
require_relative "kantan/h2/hpack"
require_relative "kantan/h2/frames"
require_relative "kantan/h2/body"
require_relative "kantan/h2/session"
