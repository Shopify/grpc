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

require_relative 'constants'
require_relative 'message_compression'
require_relative 'metadata'
require_relative 'rpc_stream'
require_relative 'status_codes'
require_relative 'time_spec'

module GRPC
  module Core
    # One RPC as seen by the surface API. Replaces rb_call.c.
    #
    # A Call is created either by Channel#create_call (client) or by
    # Server#request_call (server), and is driven exclusively through
    # #run_batch, which applies the send operations and then blocks until the
    # receive operations are satisfied.
    class Call
      include CallOps

      # The order C-core applies operations in, independent of hash order.
      OP_ORDER = [
        SEND_INITIAL_METADATA, SEND_MESSAGE, SEND_CLOSE_FROM_CLIENT,
        SEND_STATUS_FROM_SERVER, RECV_INITIAL_METADATA, RECV_MESSAGE,
        RECV_STATUS_ON_CLIENT, RECV_CLOSE_ON_SERVER
      ].freeze

      VALID_OPS = OP_ORDER.freeze

      ACCEPT_ENCODING = 'identity,deflate,gzip'

      attr_reader :metadata, :trailing_metadata, :status, :write_flag

      # Builds the client side of a call. Internal; use Channel#create_call.
      def self.client(channel:, method:, host:, deadline:, parent:, mask:)
        allocate.send(:initialize_client, channel, method, host, deadline,
                      parent, mask)
      end

      # Builds the server side of a call. Internal; use Server#request_call.
      def self.server(stream:, headers:, deadline:, server:)
        allocate.send(:initialize_server, stream, headers, deadline, server)
      end

      def initialize(*)
        fail TypeError, 'Directly allocating GRPC::Core::Call is not supported'
      end

      def initialize_copy(_other)
        fail TypeError,
             'Copy initialization of GRPC::Core::Call is not supported'
      end

      def status=(status)
        if !status.nil? && !status.is_a?(Struct::Status)
          fail TypeError,
               "bad status: got:<#{status.class}> want: <Struct::Status>"
        end
        @status = status
      end

      def metadata=(metadata)
        if !metadata.nil? && !metadata.is_a?(Hash)
          fail TypeError, "bad metadata: got:<#{metadata.class}> want: <Hash>"
        end
        @metadata = metadata
      end

      def trailing_metadata=(metadata)
        if !metadata.nil? && !metadata.is_a?(Hash)
          fail TypeError, "bad metadata: got:<#{metadata.class}> want: <Hash>"
        end
        @trailing_metadata = metadata
      end

      def write_flag=(flag)
        if !flag.nil? && !flag.is_a?(Integer)
          fail TypeError, "bad write_flag: got:<#{flag.class}> want: <Fixnum>"
        end
        @write_flag = flag
      end

      def peer
        fail CallError, 'Cannot get peer value on closed call' if @closed
        @peer
      end

      def peer_cert
        fail CallError, 'Cannot get peer cert on closed call' if @closed
        @peer_cert
      end

      def set_credentials!(credentials)
        fail CallError, 'Cannot set credentials of closed call' if @closed
        unless credentials.is_a?(CallCredentials)
          fail TypeError, 'expected a CallCredentials'
        end
        @call_credentials = credentials
        nil
      end

      # Cancels the RPC. Safe to call repeatedly and after #close.
      def cancel
        cancel_with_status(StatusCodes::CANCELLED, 'CANCELLED')
      end

      def cancel_with_status(code, details)
        unless details.is_a?(String) && code.is_a?(Integer)
          fail TypeError,
               'Bad parameter type error for cancel with status. Want Fixnum, ' \
               'String.'
        end
        return nil if @closed
        @mu.synchronize do
          return nil if @cancelled
          @cancelled = Struct::Status.new(code, details, {}, nil)
        end
        stream = @stream
        return nil if stream.nil?
        stream.reset(8) # HTTP/2 CANCEL
        # Wake anybody blocked reading this stream; the RST only tells the
        # peer, it says nothing to our own threads.
        stream.push_failure(code, details)
        @connection&.forget(stream.id)
        nil
      end

      # Releases the call. Further batches raise CallError.
      def close
        return nil if @closed
        @closed = true
        stream = @stream
        if stream && !@finished
          stream.reset(8) # CANCEL
        end
        @connection&.forget(stream.id) if stream
        nil
      end

      # Applies +ops+ and blocks until they complete.
      #
      # @param ops [Hash] CallOps constant => operation value
      # @return [Struct::BatchResult]
      def run_batch(ops)
        fail CallError, 'Cannot run batch on closed call' if @closed
        unless ops.is_a?(Hash)
          fail TypeError, 'call#run_batch: ops hash should be a hash'
        end
        ordered = validate_ops(ops)
        result = Struct::BatchResult.new(nil, nil, nil, nil, nil, nil, nil, nil)
        ordered.each { |op| apply_op(op, ops[op], result) }
        release_finished_stream
        result
      end

      private

      # Once an RPC has reached its terminal state the connection no longer
      # needs to route frames to it. Dropping it here, rather than waiting for
      # #close, lets server shutdown see the RPC as complete.
      def release_finished_stream
        return unless @finished && @stream
        return unless @client || @stream.remote_closed?
        @connection&.forget(@stream.id)
      end

      def initialize_client(channel, method, host, deadline, parent, mask)
        @client = true
        @channel = channel
        @method = method
        @host = host
        @deadline = TimeSpec.from(deadline)
        @parent = parent
        @mask = mask
        @peer = channel.target
        @peer_cert = nil
        common_init
        inherit_parent_deadline
        self
      end

      def initialize_server(stream, headers, deadline, server)
        @client = false
        @server = server
        @stream = stream
        @connection = stream.connection
        @recv_headers = headers
        @deadline = deadline
        @peer = stream.peer
        @peer_cert = stream.peer_cert
        common_init
        @headers_sent = false
        self
      end

      def common_init
        @mu = Mutex.new
        @closed = false
        @finished = false
        @cancelled = nil
        @transport_failure = nil
        @write_flag = nil
        @status = nil
        @metadata = nil
        @trailing_metadata = nil
        @call_credentials = nil
        @send_encoding = 'identity'
        @initial_metadata_received = false
        @start_attempted = false
        @monotonic_deadline = monotonic_deadline_for(@deadline)
        self
      end

      # GRPC_PROPAGATE_DEADLINE means a child call cannot outlive its parent.
      def inherit_parent_deadline
        return if @parent.nil?
        mask = @mask.nil? ? PropagateMasks::DEFAULTS : @mask
        return if (mask & PropagateMasks::DEADLINE).zero?
        parent_deadline = @parent.monotonic_deadline
        return if parent_deadline.nil?
        @monotonic_deadline =
          if @monotonic_deadline.nil?
            parent_deadline
          else
            [@monotonic_deadline, parent_deadline].min
          end
      end

      protected

      attr_reader :monotonic_deadline

      private

      def monotonic_deadline_for(deadline)
        return nil if deadline.nil?
        seconds = TimeSpec.from(deadline).to_relative_seconds
        return nil if seconds.nil?
        RpcStream.now + seconds
      end

      def validate_ops(ops)
        ops.each_key do |key|
          unless key.is_a?(Integer)
            fail TypeError,
                 "invalid operation : got <#{key.class}>, want <Fixnum>"
          end
          unless VALID_OPS.include?(key)
            fail TypeError, "invalid operation : bad value #{key}"
          end
        end
        OP_ORDER.select { |op| ops.key?(op) }
      end

      def apply_op(code, value, result)
        case code
        when SEND_INITIAL_METADATA then op_send_initial_metadata(value, result)
        when SEND_MESSAGE then op_send_message(value, result)
        when SEND_CLOSE_FROM_CLIENT then op_send_close(result)
        when SEND_STATUS_FROM_SERVER then op_send_status(value, result)
        when RECV_INITIAL_METADATA then op_recv_initial_metadata(result)
        when RECV_MESSAGE then op_recv_message(result)
        when RECV_STATUS_ON_CLIENT then op_recv_status(result)
        when RECV_CLOSE_ON_SERVER then op_recv_close(result)
        end
      end

      # ---- send operations ---------------------------------------------------

      def op_send_initial_metadata(value, result)
        result.send_metadata = true
        return if failed?
        @client ? start_client_call(value) : send_server_headers(value)
      end

      def op_send_message(value, result)
        result.send_message = true
        return if failed?
        ensure_started
        return if failed?
        no_compress = !@write_flag.nil? &&
                      (@write_flag & WriteFlags::NO_COMPRESS) != 0
        @stream.send_message(value, no_compress: no_compress)
      rescue Http2::Kantan::Errors::Error, IOError, SystemCallError => e
        record_transport_failure(e)
      end

      def op_send_close(result)
        result.send_close = true
        return if failed?
        ensure_started
        return if failed?
        @stream.close_send
      end

      def op_send_status(value, result)
        unless value.code.is_a?(Integer)
          fail TypeError,
               "invalid code : got <#{value.code.class}>, want <Fixnum>"
        end
        unless value.details.is_a?(String)
          fail TypeError,
               "invalid details : got <#{value.details.class}>, want <String>"
        end
        trailers = [['grpc-status', value.code.to_s]]
        unless value.details.empty?
          trailers << ['grpc-message', percent_encode(value.details)]
        end
        trailers.concat(Metadata.encode(value.metadata))
        result.send_status = true
        return if failed?
        send_server_headers({}) unless @headers_sent
        @stream.send_trailers(trailers)
        @finished = true
      rescue Http2::Kantan::Errors::Error, IOError, SystemCallError => e
        record_transport_failure(e)
      end

      # ---- receive operations ------------------------------------------------

      def op_recv_initial_metadata(result)
        ensure_started
        if failed?
          result.metadata = {}
          return
        end
        pairs = @stream.await_headers(@monotonic_deadline)
        @initial_metadata_received = true
        result.metadata =
          if pairs.nil?
            {}
          else
            Metadata.decode(
              pairs.reject { |n, _| Metadata::CLIENT_RESERVED.include?(n) })
          end
      end

      def op_recv_message(result)
        ensure_started
        return if failed?
        result.message = @stream.read_message(@monotonic_deadline)
      rescue RpcStream::ResourceExhausted => e
        record_status(StatusCodes::RESOURCE_EXHAUSTED, e.message)
        result.message = nil
      rescue RpcStream::Truncated, Http2::Kantan::Errors::Error, IOError,
             SystemCallError => e
        record_transport_failure(e)
        result.message = nil
      end

      def op_recv_status(result)
        ensure_started
        result.status = resolve_client_status
        @finished = true
      end

      def op_recv_close(result)
        # The C extension sets send_close for this operation too.
        result.send_close = true
        return if failed?
        @stream.await_trailers(@monotonic_deadline)
        result.cancelled = !@stream.failure.nil?
      end

      # ---- client call start -------------------------------------------------

      def start_client_call(metadata)
        @start_attempted = true
        md = metadata.nil? ? {} : metadata.dup
        requested = md.delete(MetadataKeys::COMPRESSION_REQUEST_ALGORITHM)
        credential_headers = call_credentials_headers
        return if failed?
        # Metadata errors are the caller's fault and must surface as-is, so
        # they are raised before anything touching the transport.
        headers = build_request_headers(md, requested).concat(credential_headers)
        begin
          @stream = @channel.open_stream(deadline: @monotonic_deadline)
          @connection = @stream.connection
          @peer = @stream.peer
          @peer_cert = @stream.peer_cert
          @stream.send_encoding = @send_encoding
          @stream.send_headers(headers)
        rescue StandardError => e
          record_transport_failure(e)
        end
      end

      def build_request_headers(metadata, requested_encoding)
        if requested_encoding && MessageCompression.supported?(requested_encoding)
          @send_encoding = requested_encoding
        end
        headers = [
          [':method', 'POST'],
          [':scheme', @channel.scheme],
          [':path', @method],
          [':authority', @host || @channel.authority],
          ['content-type', 'application/grpc'],
          ['user-agent', @channel.user_agent],
          ['te', 'trailers'],
          ['grpc-accept-encoding', ACCEPT_ENCODING]
        ]
        timeout = grpc_timeout
        headers << ['grpc-timeout', timeout] if timeout
        headers << ['grpc-encoding', @send_encoding] if @send_encoding != 'identity'
        headers.concat(Metadata.encode(metadata))
      end

      # Runs the metadata plugin and validates what it produced. A plugin that
      # raises, or that returns metadata gRPC cannot put on the wire, fails the
      # RPC with UNAVAILABLE instead of raising at the caller, which is what
      # C-core does.
      def call_credentials_headers
        creds = @call_credentials || @channel.call_credentials
        return [] if creds.nil?
        return [] unless @channel.secure?
        context = {
          service_url: "https://#{@channel.authority}#{service_path}",
          jwt_aud_uri: "https://#{@channel.authority}#{service_path}",
          method_name: method_name
        }
        produced = creds.get_metadata(context)
        return [] if produced.nil?
        unless produced.is_a?(Hash)
          fail TypeError,
               "Call credentials must return Hash or nil, got #{produced.class}"
        end
        Metadata.encode(produced)
      rescue StandardError => e
        record_status(
          StatusCodes::UNAVAILABLE,
          "Getting metadata from plugin failed with error: #{e.message}")
        []
      end

      def service_path
        index = @method.rindex('/')
        index&.positive? ? @method[0, index] : ''
      end

      def method_name
        index = @method.rindex('/')
        index ? @method[(index + 1)..] : @method
      end

      # gRPC timeouts are an integer plus a unit; nanoseconds keep precision
      # for the sub-second deadlines the tests use.
      def grpc_timeout
        return nil if @monotonic_deadline.nil?
        remaining = @monotonic_deadline - RpcStream.now
        remaining = 0 if remaining.negative?
        micros = (remaining * 1_000_000).round
        return "#{micros}u" if micros < 100_000_000
        "#{(micros / 1000.0).round}m"
      end

      # A client call is started at most once. Retrying would re-invoke the
      # metadata plugin and re-send headers after a failed start.
      #
      # Reaching here means the batch had no SEND_INITIAL_METADATA operation
      # (operations run in CallOps order, so that one always runs first when
      # present), so there is no caller metadata to send and the call starts
      # with headers only, as C-core does.
      def ensure_started
        return unless @client
        return if @start_attempted
        start_client_call({})
      end

      # ---- server responses --------------------------------------------------

      def send_server_headers(metadata)
        headers = [
          [':status', '200'],
          ['content-type', 'application/grpc']
        ]
        headers.concat(Metadata.encode(metadata))
        @headers_sent = true
        @stream.send_headers(headers)
      rescue Http2::Kantan::Errors::Error, IOError, SystemCallError => e
        record_transport_failure(e)
      end

      # ---- status assembly ---------------------------------------------------

      def resolve_client_status
        cancelled = @mu.synchronize { @cancelled }
        return with_debug(cancelled) if cancelled
        return with_debug(@transport_failure) if @transport_failure
        pairs = @stream.await_trailers(@monotonic_deadline)
        if @stream.failure
          failure = @stream.failure
          return with_debug(Struct::Status.new(failure.code, failure.details,
                                               {}, nil))
        end
        if pairs.empty? && deadline_passed?
          return with_debug(Struct::Status.new(StatusCodes::DEADLINE_EXCEEDED,
                                               'Deadline Exceeded', {}, nil))
        end
        status_from_trailers(pairs)
      rescue Http2::Kantan::Errors::Error, IOError, SystemCallError => e
        record_transport_failure(e)
        with_debug(@transport_failure)
      end

      def status_from_trailers(pairs)
        code = lookup(pairs, 'grpc-status')
        if code.nil?
          return with_debug(Struct::Status.new(
                              StatusCodes::UNKNOWN,
                              'Missing grpc-status in trailers', {}, nil))
        end
        details = lookup(pairs, 'grpc-message')
        metadata = Metadata.decode(
          pairs.reject { |n, _| %w[grpc-status grpc-message].include?(n) })
        with_debug(Struct::Status.new(code.to_i,
                                      details ? percent_decode(details) : '',
                                      metadata, nil))
      end

      # C-core attaches a JSON diagnostic blob to every failed RPC; the Ruby
      # error message format depends on it starting with '{'.
      def with_debug(status)
        return status if status.code == StatusCodes::OK
        debug = '"created":"@' \
                "#{Time.now.to_f}\",\"description\":\"Error received from peer\"" \
                ",\"grpc_message\":#{status.details.to_s.inspect}" \
                ",\"grpc_status\":#{status.code}"
        Struct::Status.new(status.code, status.details, status.metadata, debug)
      end

      def lookup(pairs, name)
        pairs.find { |n, _| n == name }&.last
      end

      def deadline_passed?
        !@monotonic_deadline.nil? && RpcStream.now >= @monotonic_deadline
      end

      def failed?
        !@transport_failure.nil? || !@mu.synchronize { @cancelled }.nil?
      end

      def record_transport_failure(error)
        code, details = classify(error)
        record_status(code, details)
      end

      def record_status(code, details)
        @transport_failure ||= Struct::Status.new(code, details, {}, nil)
        nil
      end

      def classify(error)
        case error
        when RpcStream::ResourceExhausted
          [StatusCodes::RESOURCE_EXHAUSTED, error.message]
        when OpenSSL::SSL::SSLError
          [StatusCodes::UNAVAILABLE, "Handshake failed: #{error.message}"]
        else
          [StatusCodes::UNAVAILABLE, "#{error.class}: #{error.message}"]
        end
      end

      # grpc-message uses percent encoding for bytes outside %x20-%x7E and '%'.
      def percent_encode(text)
        text.b.gsub(/[^\x20-\x24\x26-\x7e]/n) do |byte|
          format('%%%02X', byte.ord)
        end
      end

      def percent_decode(text)
        text.gsub(/%([0-9A-Fa-f]{2})/) { Regexp.last_match(1).hex.chr }
            .force_encoding(Encoding::UTF_8)
      end
    end
  end
end
