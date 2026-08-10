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

require_relative 'active_call'
require_relative '../version'

# GRPC contains the General RPC module.
module GRPC
  # rubocop:disable Metrics/ParameterLists

  # ClientStub represents a client connection to a gRPC server, and can be used
  # to send requests.
  class ClientStub
    include Core::StatusCodes
    include Core::TimeConsts

    # Default timeout is infinity.
    DEFAULT_TIMEOUT = INFINITE_FUTURE

    # setup_channel is used by #initialize to constuct a channel from its
    # arguments.
    def self.setup_channel(alt_chan, host, creds, channel_args = {})
      unless alt_chan.nil?
        fail(TypeError, '!Channel') unless alt_chan.is_a?(Core::Channel)
        return alt_chan
      end
      if channel_args['grpc.primary_user_agent'].nil?
        channel_args['grpc.primary_user_agent'] = ''
      else
        channel_args['grpc.primary_user_agent'] += ' '
      end
      channel_args['grpc.primary_user_agent'] += "grpc-ruby/#{VERSION}"
      unless creds.is_a?(Core::ChannelCredentials) ||
             creds.is_a?(Core::XdsChannelCredentials) ||
             creds.is_a?(Symbol)
        fail(TypeError, 'creds is not a ChannelCredentials, XdsChannelCredentials, or Symbol')
      end
      Core::Channel.new(host, channel_args, creds)
    end

    # Allows users of the stub to modify the propagate mask.
    #
    # This is an advanced feature for use when making calls to another gRPC
    # server whilst running in the handler of an existing one.
    attr_writer :propagate_mask

    # Creates a new ClientStub.
    #
    # Minimally, a stub is created with the just the host of the gRPC service
    # it wishes to access, e.g.,
    #
    #   my_stub = ClientStub.new("example.host.com:50505",
    #                            :this_channel_is_insecure)
    #
    # If a channel_override argument is passed, it will be used as the
    # underlying channel. Otherwise, the channel_args argument will be used
    # to construct a new underlying channel.
    #
    # There are some specific keyword args that are not used to configure the
    # channel:
    #
    # - :channel_override
    # when present, this must be a pre-created GRPC::Core::Channel.  If it's
    # present the host and arbitrary keyword args are ignored, and the RPC
    # connection uses this channel.
    #
    # - :timeout
    # when present, this is the default timeout used for calls
    #
    # @param host [String] the host the stub connects to
    # @param creds [Core::ChannelCredentials|Core::CallCredentials|Symbol]
    #     ChannelCredentials, CallCredentials (creates default SSL channel), or
    #     :this_channel_is_insecure. Ignored if channel_override is provided.
    # @param channel_override [Core::Channel] a pre-created channel
    # @param timeout [Number] the default timeout to use in requests
    # @param propagate_mask [Number] A bitwise combination of flags in
    #     GRPC::Core::PropagateMasks. Indicates how data should be propagated
    #     from parent server calls to child client calls if this client is being
    #     used within a gRPC server.
    # @param channel_args [Hash] the channel arguments. Note: this argument is
    #     ignored if the channel_override argument is provided.
    # @param interceptors [Array<GRPC::ClientInterceptor>] An array of
    #     GRPC::ClientInterceptor objects that will be used for
    #     intercepting calls before they are executed
    #     Interceptors are an EXPERIMENTAL API.
    def initialize(host, creds,
                   channel_override: nil,
                   timeout: nil,
                   propagate_mask: nil,
                   channel_args: {},
                   interceptors: [])
      # Split credentials: CallCredentials alone create a default secure channel.
      # CompositeChannelCredentials splitting is handled by Core::CompositeCredentialsHandler
      # module when the pure Ruby toggle is enabled.
      if creds.is_a?(Core::CallCredentials)
        @call_creds    = creds
        @channel_creds = Core::ChannelCredentials.new
      else
        @call_creds    = nil
        @channel_creds = creds
      end

      @ch = ClientStub.setup_channel(channel_override, host, @channel_creds,
                                     channel_args.dup)
      alt_host = channel_args[Core::Channel::SSL_TARGET]
      @host = alt_host.nil? ? host : alt_host
      @propagate_mask = propagate_mask
      @timeout = timeout.nil? ? DEFAULT_TIMEOUT : timeout
      @interceptors = InterceptorRegistry.new(interceptors)
    end

    # request_response sends a request to a GRPC server, and returns the
    # response.
    #
    # == Flow Control ==
    # This is a blocking call.
    #
    # * it does not return until a response is received.
    #
    # * the request is sent only when GRPC core's flow control allows it to
    #   be sent.
    #
    # == Errors ==
    # A RuntimeError is raised if
    #
    # * the server responds with a non-OK status
    #
    # * the deadline is exceeded
    #
    # == Return Value ==
    #
    # If return_op is false, the call returns the response
    #
    # If return_op is true, the call returns an Operation, calling execute
    # on the Operation returns the response.
    #
    # @param method [String] the RPC method to call on the GRPC server
    # @param req [Object] the request sent to the server
    # @param marshal [Function] f(obj)->string that marshals requests
    # @param unmarshal [Function] f(string)->obj that unmarshals responses
    # @param deadline [Time] (optional) the time the request should complete
    # @param return_op [true|false] return an Operation if true
    # @param parent [Core::Call] a prior call whose reserved metadata
    #   will be propagated by this one.
    # @param credentials [Core::CallCredentials] credentials to use when making
    #   the call
    # @param metadata [Hash] metadata to be sent to the server
    # @return [Object] the response received from the server
    def request_response(method, req, marshal, unmarshal,
                         deadline: nil,
                         return_op: false,
                         parent: nil,
                         credentials: nil,
                         metadata: {})
      c = new_active_call(method, marshal, unmarshal,
                          deadline: deadline, parent: parent,
                          credentials: credentials)

      intercept_args = {
        method: method,
        request: req,
        call: c.interceptable,
        metadata: metadata
      }

      handle_return_op(c, return_op, metadata, credentials, method) do
        execute_with_interceptors(:request_response, intercept_args, credentials, method, c) do |resolved_md|
          retry_policy = @ch.retries_enabled?(method) && retry_policy_for(method)
          if retry_policy
            request_response_with_retries(method, req, marshal, unmarshal, c,
                                          resolved_md, retry_policy,
                                          parent: parent, credentials: credentials)
          else
            c.request_response(req, metadata: resolved_md)
          end
        end
      end
    end

    # client_streamer sends a stream of requests to a GRPC server, and
    # returns a single response.
    #
    # requests provides an 'iterable' of Requests. I.e. it follows Ruby's
    # #each enumeration protocol. In the simplest case, requests will be an
    # array of marshallable objects; in typical case it will be an Enumerable
    # that allows dynamic construction of the marshallable objects.
    #
    # == Flow Control ==
    # This is a blocking call.
    #
    # * it does not return until a response is received.
    #
    # * each requests is sent only when GRPC core's flow control allows it to
    #   be sent.
    #
    # == Errors ==
    # An RuntimeError is raised if
    #
    # * the server responds with a non-OK status
    #
    # * the deadline is exceeded
    #
    # == Return Value ==
    #
    # If return_op is false, the call consumes the requests and returns
    # the response.
    #
    # If return_op is true, the call returns the response.
    #
    # @param method [String] the RPC method to call on the GRPC server
    # @param requests [Object] an Enumerable of requests to send
    # @param marshal [Function] f(obj)->string that marshals requests
    # @param unmarshal [Function] f(string)->obj that unmarshals responses
    # @param deadline [Time] (optional) the time the request should complete
    # @param return_op [true|false] return an Operation if true
    # @param parent [Core::Call] a prior call whose reserved metadata
    #   will be propagated by this one.
    # @param credentials [Core::CallCredentials] credentials to use when making
    #   the call
    # @param metadata [Hash] metadata to be sent to the server
    # @return [Object|Operation] the response received from the server
    def client_streamer(method, requests, marshal, unmarshal,
                        deadline: nil,
                        return_op: false,
                        parent: nil,
                        credentials: nil,
                        metadata: {})
      c = new_active_call(method, marshal, unmarshal,
                          deadline: deadline, parent: parent,
                          credentials: credentials)

      intercept_args = {
        method: method,
        requests: requests,
        call: c.interceptable,
        metadata: metadata
      }

      handle_return_op(c, return_op, metadata, credentials, method) do
        execute_with_interceptors(:client_streamer, intercept_args, credentials, method, c) do |resolved_md|
          c.client_streamer(requests, metadata: resolved_md)
        end
      end
    end

    # server_streamer sends one request to the GRPC server, which yields a
    # stream of responses.
    #
    # responses provides an enumerator over the streamed responses, i.e. it
    # follows Ruby's #each iteration protocol.  The enumerator blocks while
    # waiting for each response, stops when the server signals that no
    # further responses will be supplied.  If the implicit block is provided,
    # it is executed with each response as the argument and no result is
    # returned.
    #
    # == Flow Control ==
    # This is a blocking call.
    #
    # * the request is sent only when GRPC core's flow control allows it to
    #   be sent.
    #
    # * the request will not complete until the server sends the final
    #   response followed by a status message.
    #
    # == Errors ==
    # An RuntimeError is raised if
    #
    # * the server responds with a non-OK status when any response is
    # * retrieved
    #
    # * the deadline is exceeded
    #
    # == Return Value ==
    #
    # if the return_op is false, the return value is an Enumerator of the
    # results, unless a block is provided, in which case the block is
    # executed with each response.
    #
    # if return_op is true, the function returns an Operation whose #execute
    # method runs server streamer call. Again, Operation#execute either
    # calls the given block with each response or returns an Enumerator of the
    # responses.
    #
    # == Keyword Args ==
    #
    # Unspecified keyword arguments are treated as metadata to be sent to the
    # server.
    #
    # @param method [String] the RPC method to call on the GRPC server
    # @param req [Object] the request sent to the server
    # @param marshal [Function] f(obj)->string that marshals requests
    # @param unmarshal [Function] f(string)->obj that unmarshals responses
    # @param deadline [Time] (optional) the time the request should complete
    # @param return_op [true|false]return an Operation if true
    # @param parent [Core::Call] a prior call whose reserved metadata
    #   will be propagated by this one.
    # @param credentials [Core::CallCredentials] credentials to use when making
    #   the call
    # @param metadata [Hash] metadata to be sent to the server
    # @param blk [Block] when provided, is executed for each response
    # @return [Enumerator|Operation|nil] as discussed above
    def server_streamer(method, req, marshal, unmarshal,
                        deadline: nil,
                        return_op: false,
                        parent: nil,
                        credentials: nil,
                        metadata: {},
                        &blk)
      c = new_active_call(method, marshal, unmarshal,
                          deadline: deadline, parent: parent,
                          credentials: credentials)

      intercept_args = {
        method: method,
        request: req,
        call: c.interceptable,
        metadata: metadata
      }

      handle_return_op(c, return_op, metadata, credentials, method) do
        execute_with_interceptors(:server_streamer, intercept_args, credentials, method, c) do |resolved_md|
          c.server_streamer(req, metadata: resolved_md, &blk)
        end
      end
    end

    # bidi_streamer sends a stream of requests to the GRPC server, and yields
    # a stream of responses.
    #
    # This method takes an Enumerable of requests, and returns and enumerable
    # of responses.
    #
    # == requests ==
    #
    # requests provides an 'iterable' of Requests. I.e. it follows Ruby's
    # #each enumeration protocol. In the simplest case, requests will be an
    # array of marshallable objects; in typical case it will be an
    # Enumerable that allows dynamic construction of the marshallable
    # objects.
    #
    # == responses ==
    #
    # This is an enumerator of responses.  I.e, its #next method blocks
    # waiting for the next response.  Also, if at any point the block needs
    # to consume all the remaining responses, this can be done using #each or
    # #collect.  Calling #each or #collect should only be done if
    # the_call#writes_done has been called, otherwise the block will loop
    # forever.
    #
    # == Flow Control ==
    # This is a blocking call.
    #
    # * the call completes when the next call to provided block returns
    #   false
    #
    # * the execution block parameters are two objects for sending and
    #   receiving responses, each of which blocks waiting for flow control.
    #   E.g, calles to bidi_call#remote_send will wait until flow control
    #   allows another write before returning; and obviously calls to
    #   responses#next block until the next response is available.
    #
    # == Termination ==
    #
    # As well as sending and receiving messages, the block passed to the
    # function is also responsible for:
    #
    # * calling bidi_call#writes_done to indicate no further reqs will be
    #   sent.
    #
    # * returning false if once the bidi stream is functionally completed.
    #
    # Note that response#next will indicate that there are no further
    # responses by throwing StopIteration, but can only happen either
    # if bidi_call#writes_done is called.
    #
    # To properly terminate the RPC, the responses should be completely iterated
    # through; one way to do this is to loop on responses#next until no further
    # responses are available.
    #
    # == Errors ==
    # An RuntimeError is raised if
    #
    # * the server responds with a non-OK status when any response is
    # * retrieved
    #
    # * the deadline is exceeded
    #
    #
    # == Return Value ==
    #
    # if the return_op is false, the return value is an Enumerator of the
    # results, unless a block is provided, in which case the block is
    # executed with each response.
    #
    # if return_op is true, the function returns an Operation whose #execute
    # method runs the Bidi call. Again, Operation#execute either calls a
    # given block with each response or returns an Enumerator of the
    # responses.
    #
    # @param method [String] the RPC method to call on the GRPC server
    # @param requests [Object] an Enumerable of requests to send
    # @param marshal [Function] f(obj)->string that marshals requests
    # @param unmarshal [Function] f(string)->obj that unmarshals responses
    # @param deadline [Time] (optional) the time the request should complete
    # @param return_op [true|false] return an Operation if true
    # @param parent [Core::Call] a prior call whose reserved metadata
    #   will be propagated by this one.
    # @param credentials [Core::CallCredentials] credentials to use when making
    #   the call
    # @param metadata [Hash] metadata to be sent to the server
    # @param blk [Block] when provided, is executed for each response
    # @return [Enumerator|nil|Operation] as discussed above
    def bidi_streamer(method, requests, marshal, unmarshal,
                      deadline: nil,
                      return_op: false,
                      parent: nil,
                      credentials: nil,
                      metadata: {},
                      &blk)
      c = new_active_call(method, marshal, unmarshal,
                          deadline: deadline, parent: parent,
                          credentials: credentials)

      intercept_args = {
        method: method,
        requests: requests,
        call: c.interceptable,
        metadata: metadata
      }

      handle_return_op(c, return_op, metadata, credentials, method) do
        execute_with_interceptors(:bidi_streamer, intercept_args, credentials, method, c) do |resolved_md|
          c.bidi_streamer(requests, metadata: resolved_md, &blk)
        end
      end
    end

    private

    # Creates a new active stub
    #
    # @param method [string] the method being called.
    # @param marshal [Function] f(obj)->string that marshals requests
    # @param unmarshal [Function] f(string)->obj that unmarshals responses
    # @param deadline [Time] (optional) the time the request should complete
    # @param parent [Grpc::Call] a parent call, available when calls are
    #   made from server
    # @param credentials [Core::CallCredentials] credentials to use when making
    #   the call
    def new_active_call(method, marshal, unmarshal,
                        deadline: nil,
                        parent: nil,
                        credentials: nil)
      if deadline.nil?
        # The service config's timeout is the deadline the caller gets when
        # it named none; @timeout (the stub-wide default) only applies when
        # the service config says nothing about this method either.
        default_timeout = @ch.method_config(method)&.timeout || @timeout
        deadline = from_relative_time(default_timeout)
      end
      # Provide each new client call with its own completion queue
      call = @ch.create_call(parent, # parent call
                             @propagate_mask, # propagation options
                             method,
                             nil, # host use nil,
                             deadline)
      call.set_credentials! credentials unless credentials.nil?
      ActiveCall.new(call, marshal, unmarshal, deadline,
                     started: false)
    end

    # Returns the retry policy that applies to +method+, or nil.
    def retry_policy_for(method)
      @ch.method_config(method)&.retry_policy
    end

    # Drives the retry loop for a unary call. +first_call+ has already sent
    # nothing; each subsequent attempt gets a brand new ActiveCall (and thus
    # a fresh Core::Call) sharing the one absolute deadline, since a Call is
    # single-use once run_batch has touched it.
    #
    # A unary #request_response only ever returns after RECV_STATUS_ON_CLIENT
    # has arrived alongside RECV_MESSAGE in the same batch, and raises before
    # handing a message to the caller when the status is bad. That makes
    # every attempt here uncommitted by construction: this method is never
    # reached again once an attempt has returned a value to the caller.
    def request_response_with_retries(method, req, marshal, unmarshal, first_call,
                                      metadata, retry_policy, parent:, credentials:)
      deadline = first_call.deadline
      call = first_call
      attempt = 1
      begin
        call.request_response(req, metadata: attempt_metadata(metadata, attempt))
      rescue GRPC::BadStatus => e
        backoff = attempt < retry_policy.max_attempts ? retry_backoff(e, retry_policy, attempt, deadline) : nil
        raise e if backoff.nil?
        sleep(backoff)
        attempt += 1
        call = new_active_call(method, marshal, unmarshal,
                               deadline: deadline, parent: parent, credentials: credentials)
        retry
      end
    end

    # Adds grpc-previous-rpc-attempts from the second attempt on, as
    # https://github.com/grpc/proposal/blob/master/A6-client-retries.md
    # requires so the server can tell attempts apart.
    def attempt_metadata(metadata, attempt)
      return metadata if attempt == 1
      metadata.merge('grpc-previous-rpc-attempts' => (attempt - 1).to_s)
    end

    # nil means "give up, raise the error that got us here": either the
    # trailers said to (a negative grpc-retry-pushback-ms), the status isn't
    # retryable and the server offered no pushback, or waiting for the next
    # attempt would run past the call's own deadline.
    def retry_backoff(bad_status, retry_policy, attempt, deadline)
      pushback = retry_pushback_ms(bad_status.metadata)
      return nil if pushback&.negative?
      return nil if pushback.nil? && !retry_policy.retryable_status_codes.include?(bad_status.code)
      backoff = pushback ? pushback / 1000.0 : exponential_backoff(retry_policy, attempt)
      remaining = Core::TimeSpec.from(deadline).to_relative_seconds
      return nil if remaining && remaining <= 0
      remaining.nil? ? backoff : [backoff, remaining].min
    end

    # currentBackoff = min(initialBackoff * backoffMultiplier**(attempt - 1),
    # maxBackoff), then a jittered wait uniformly random in [0, currentBackoff)
    # so retrying clients spread out instead of hammering the server in
    # lockstep, per the retry design's backoff formula.
    def exponential_backoff(retry_policy, attempt)
      current = retry_policy.initial_backoff *
                (retry_policy.backoff_multiplier**(attempt - 1))
      rand * [current, retry_policy.max_backoff].min
    end

    # The server's escape hatch for overriding this client's own backoff and
    # retryableStatusCodes: absent, malformed, or non-numeric all mean "the
    # server said nothing", not "stop retrying".
    def retry_pushback_ms(metadata)
      value = metadata && metadata['grpc-retry-pushback-ms']
      return nil if value.nil?
      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    # Runs the interceptor chain and resolves metadata/credentials exactly once
    # at the end of the chain.
    def execute_with_interceptors(rpc_type, intercept_args, credentials, method, call)
      interception_context = @interceptors.build_context
      call_started = false
      already_finished = !call.status.nil?
      begin
        interception_context.intercept!(rpc_type, intercept_args) do
          resolved_md = resolve_call_metadata(intercept_args[:metadata], credentials, method)
          call_started = true
          yield(resolved_md)
        end
      rescue StandardError => e
        call.op_is_done unless call_started || already_finished
        raise e
      end
    end

    # Handles return_op lifecycle branching
    def handle_return_op(call, return_op, metadata, credentials, method, &block)
      if return_op
        stub = self
        op = call.operation
        op.define_singleton_method(:execute) do
          block.call
        end
        op.define_singleton_method(:start_call) do |op_metadata = {}|
          resolved_md = stub.send(:resolve_call_metadata, metadata, credentials, method)
          call.merge_metadata_to_send(resolved_md.merge(op_metadata))
          call.send_initial_metadata
        rescue StandardError => e
          call.op_is_done unless call.metadata_sent
          raise e
        end
        op
      else
        yield
      end
    end

    def resolve_call_metadata(metadata, _credentials, _method)
      metadata
    end

    private :resolve_call_metadata, :execute_with_interceptors, :handle_return_op
  end
end
