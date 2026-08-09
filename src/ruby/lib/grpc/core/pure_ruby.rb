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

# Loads the pure Ruby implementation of GRPC::Core, which replaces the
# grpc_c extension. Everything the C extension defined is defined here.

require_relative '../structs'

# The structs the C extension registered on Struct.
# The :method member shadows Struct#method; the C extension defined it that
# way and GRPC::RpcServer reads an_rpc.method.
Struct.new('NewServerRpc', :method, :host, :deadline, :metadata, # rubocop:disable Lint/StructNewOverride
           :call)
Struct.new('BatchResult', :send_message, :send_metadata, :send_close,
           :send_status, :message, :metadata, :status, :cancelled)

require_relative 'constants'
require_relative 'status_codes'
require_relative 'time_spec'
require_relative 'call_credentials'
require_relative 'credentials'
require_relative 'compression_options'
require_relative 'message_compression'
require_relative 'metadata'
require_relative 'channel_args'
require_relative 'transport'
require_relative 'rpc_stream'
require_relative 'connection'
require_relative 'call'
require_relative 'channel'
require_relative 'server'

module GRPC
  # The C extension refused to run between prefork and postfork, and counted
  # threads that were mid-operation, because C-core owned process-wide native
  # state and background threads. The pure Ruby implementation owns neither,
  # so the only thing a fork breaks is the sockets and session threads a child
  # inherits, which postfork_child discards.
  module Core
    module_function

    def fork_unsafe_begin
      nil
    end

    def fork_unsafe_end
      nil
    end
  end

  module_function

  # Called in the parent before forking. Nothing needs quiescing.
  def prefork
    nil
  end

  # Called in the child after forking. The channels the child inherited still
  # reference the parent's sockets and no longer have the threads that drive
  # them, so their transports are dropped; the next RPC reconnects.
  def postfork_child
    Core::Channel.reset_all_after_fork!
    nil
  end

  # Called in the parent after forking. The parent's transports are intact.
  def postfork_parent
    nil
  end
end
