# Copyright 2015 gRPC authors.
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

# GRPC contains the General RPC module.
module GRPC
  def self.logger=(logger_obj)
    # Need a free variable here to keep value of logger_obj for logger closure
    @logger = logger_obj

    extend(
      Module.new do
        def logger
          @logger
        end
      end
    )
  end

  # DefaultLogger is a module included in GRPC if no other logging is set up for
  # it.  See ../spec/spec_helpers an example of where other logging is added.
  module DefaultLogger
    def logger
      LOGGER
    end

    private

    # NoopLogger implements the methods of Ruby's conventional logging interface
    # that are actually used internally within gRPC with a noop implementation.
    class NoopLogger
      def info(_ignored)
      end

      def debug(_ignored)
      end

      def warn(_ignored)
      end
    end

    LOGGER = NoopLogger.new
  end

  # Internal logging helpers.
  #
  # Building a log message often costs more than the work being described:
  # interpolating a request body on every message, or asking for the time on
  # every call. gRPC logs nothing at all by default, so that work is usually
  # thrown away. These build the message only when a logger will take it.
  #
  # The message is handed over positionally and never as a block. GRPC.logger
  # accepts any object a user supplies, and plenty of them define debug(msg)
  # with a required argument; calling such a logger with a block and no
  # argument raises ArgumentError.
  def self.log_debug
    log = logger
    return nil if log.is_a?(DefaultLogger::NoopLogger)
    return nil if log.respond_to?(:debug?) && !log.debug?
    log.debug(yield)
    nil
  end

  def self.log_info
    log = logger
    return nil if log.is_a?(DefaultLogger::NoopLogger)
    return nil if log.respond_to?(:info?) && !log.info?
    log.info(yield)
    nil
  end

  def self.log_warn
    log = logger
    return nil if log.is_a?(DefaultLogger::NoopLogger)
    return nil if log.respond_to?(:warn?) && !log.warn?
    log.warn(yield)
    nil
  end

  # Inject the noop #logger if no module-level logger method has been injected.
  extend DefaultLogger unless methods.include?(:logger)
end
