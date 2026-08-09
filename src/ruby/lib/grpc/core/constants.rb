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

module GRPC
  module Core
    # Batch operation types. Mirrors grpc_op_type in grpc.h.
    module CallOps
      SEND_INITIAL_METADATA = 0
      SEND_MESSAGE = 1
      SEND_CLOSE_FROM_CLIENT = 2
      SEND_STATUS_FROM_SERVER = 3
      RECV_INITIAL_METADATA = 4
      RECV_MESSAGE = 5
      RECV_STATUS_ON_CLIENT = 6
      RECV_CLOSE_ON_SERVER = 7
    end

    # Per-message write flags. Mirrors GRPC_WRITE_* in grpc_types.h.
    module WriteFlags
      BUFFER_HINT = 0x00000001
      NO_COMPRESS = 0x00000002
    end

    # Errors returned when a batch cannot be started. Mirrors grpc_call_error.
    module RpcErrors
      OK = 0
      ERROR = 1
      NOT_ON_SERVER = 2
      NOT_ON_CLIENT = 3
      ALREADY_ACCEPTED = 4
      ALREADY_INVOKED = 5
      NOT_INVOKED = 6
      ALREADY_FINISHED = 7
      TOO_MANY_OPERATIONS = 8
      INVALID_FLAGS = 9

      ErrorMessages = { # rubocop:disable Naming/ConstantName
        OK => 'ok',
        ERROR => 'unknown error',
        NOT_ON_SERVER => 'not available on a server',
        NOT_ON_CLIENT => 'not available on a client',
        ALREADY_ACCEPTED => 'call is already accepted',
        ALREADY_INVOKED => 'call is already invoked',
        NOT_INVOKED => 'call is not yet invoked',
        ALREADY_FINISHED => 'call is already finished',
        TOO_MANY_OPERATIONS => 'outstanding read or write present',
        INVALID_FLAGS => 'a bad flag was given'
      }.freeze
    end

    # Metadata keys that gRPC interprets rather than transmits verbatim.
    module MetadataKeys
      COMPRESSION_REQUEST_ALGORITHM = 'grpc-internal-encoding-request'
    end

    # Channel connectivity states. Mirrors grpc_connectivity_state.
    module ConnectivityStates
      IDLE = 0
      CONNECTING = 1
      READY = 2
      TRANSIENT_FAILURE = 3
      FATAL_FAILURE = 4
    end

    # Bits controlling what a child call inherits from its parent.
    module PropagateMasks
      DEADLINE = 1
      CENSUS_STATS_CONTEXT = 2
      CENSUS_TRACING_CONTEXT = 4
      CANCELLATION = 8
      DEFAULTS = 0xffff
    end

    # Raised when a batch cannot be started or a closed call is used.
    # It derives from Exception, like the C extension class did, so that it is
    # not swallowed by a bare `rescue`.
    class CallError < Exception; end # rubocop:disable Lint/InheritException

    # Raised when a deadline passes before an operation completes.
    class OutOfTime < Exception; end # rubocop:disable Lint/InheritException

    # Placeholder retained for API compatibility with the C extension, which
    # exposed the wrapper around grpc_metadata_array under this name.
    class MetadataArray
      private_class_method :new
    end
  end
end
