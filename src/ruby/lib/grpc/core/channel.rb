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

require_relative '../version'
require_relative 'call'
require_relative 'channel_args'
require_relative 'connection'
require_relative 'constants'
require_relative 'credentials'
require_relative 'lb_policy'
require_relative 'outlier_detection'
require_relative 'reconnect_backoff'
require_relative 'service_config'
require_relative 'subchannel'
require_relative 'transport'

module GRPC
  module Core
    # A client-side channel to one target. Replaces rb_channel.c.
    #
    # The transport is created lazily: the first RPC, or an explicit
    # connectivity_state(true), opens the socket. Connection loss moves the
    # channel back to IDLE so that the next RPC reconnects.
    class Channel
      SSL_TARGET = :'grpc.ssl_target_name_override'
      ENABLE_CENSUS = :'grpc.census'
      MAX_CONCURRENT_STREAMS = :'grpc.max_concurrent_streams'
      MAX_MESSAGE_LENGTH = :'grpc.max_receive_message_length'

      # How often #await_connection re-checks after a wait, bounding the
      # cost of a missed wakeup instead of trying to eliminate it: waking
      # this often is cheap next to a connection attempt, and it lets the
      # lock stay released while #maybe_start_connect pokes a Subchannel.
      AWAIT_POLL_INTERVAL = 0.02

      # Every live channel, weakly held, so that GRPC.postfork_child can drop
      # the transports a child process inherited but cannot drive.
      LIVE = ObjectSpace::WeakMap.new

      # Discards the inherited transport of every channel in this process.
      # Only safe to call in a freshly forked child, where a single thread
      # runs and the inherited mutexes may be held by threads that are gone.
      def self.reset_all_after_fork!
        LIVE.each_key(&:reset_after_fork!)
        nil
      end

      attr_reader :target, :call_credentials, :default_compression_algorithm,
                  :max_metadata_size, :absolute_max_metadata_size,
                  :per_rpc_retry_buffer_size

      def initialize(target, channel_args, credentials)
        @target = target
        @args = ChannelArgs.normalize(channel_args)
        @credentials = resolve_credentials(credentials)
        @parsed_target = Transport.parse_target(target)
        read_channel_args
        @backoff = build_backoff
        @service_config = build_service_config
        @resolved_service_config = nil
        @resolved_service_config_looked_up = false
        @service_config_mu = Mutex.new
        @enable_retries_arg = @args[ChannelArgs::ENABLE_RETRIES]
        @enable_hedging_arg = @args[ChannelArgs::EXPERIMENTAL_ENABLE_HEDGING]
        @mu = Mutex.new
        @cv = ConditionVariable.new
        @state = ConnectivityStates::IDLE
        # One Subchannel per resolved address, plus the policy that picks
        # among them; nil until #maybe_start_connect resolves the target
        # for the first time, and again after every address has failed and
        # #schedule_reresolve_locked has torn the stale set down.
        @subchannels = nil
        @lb_policy = nil
        @resolving = false
        @resolve_thread = nil
        @idle_timer = nil
        # The handle Transport.watch_addresses returned, set once by the
        # first #resolve_worker and cancelled by #destroy; nil until then,
        # and for the whole life of a tcp:/unix: channel, whose no-op
        # handle is still stored here so #destroy has one uniform thing to
        # cancel.
        @resolver_watch = nil
        # Owned by, and only ever running while, the OutlierDetectionPolicy
        # it was started for is still @lb_policy -- see
        # #start_outlier_detection_timer_locked and #stop_outlier_detection_timer.
        @outlier_detection_timer = nil
        @last_error = nil
        @destroyed = false
        LIVE[self] = true
      end

      # Every setting this channel takes from its arguments. Kept apart from
      # #initialize because the list grows with each feature, and the wiring
      # is not what a reader of #initialize is there to find.
      def read_channel_args
        @max_receive_message_length = ChannelArgs.int(
          @args, ChannelArgs::MAX_RECEIVE_MESSAGE_LENGTH,
          ChannelArgs::DEFAULT_MAX_RECEIVE_MESSAGE_LENGTH)
        @max_send_message_length = ChannelArgs.int(
          @args, ChannelArgs::MAX_SEND_MESSAGE_LENGTH, RpcStream::NO_LIMIT)
        @default_compression_algorithm = ChannelArgs.compression_algorithm(@args)
        @max_metadata_size = ChannelArgs.int(
          @args, ChannelArgs::MAX_METADATA_SIZE,
          ChannelArgs::DEFAULT_MAX_METADATA_SIZE)
        @absolute_max_metadata_size = ChannelArgs.int(
          @args, ChannelArgs::ABSOLUTE_MAX_METADATA_SIZE, @max_metadata_size)
        @per_rpc_retry_buffer_size = ChannelArgs.int(
          @args, ChannelArgs::PER_RPC_RETRY_BUFFER_SIZE,
          ChannelArgs::DEFAULT_PER_RPC_RETRY_BUFFER_SIZE)
        @keepalive_time = ChannelArgs.seconds(@args, ChannelArgs::KEEPALIVE_TIME_MS)
        @keepalive_timeout =
          ChannelArgs.seconds(@args, ChannelArgs::KEEPALIVE_TIMEOUT_MS) ||
          Connection::DEFAULT_KEEPALIVE_TIMEOUT
        @keepalive_permit_without_calls = !ChannelArgs.int(
          @args, ChannelArgs::KEEPALIVE_PERMIT_WITHOUT_CALLS, 0
        ).zero?
        @lb_policy_name = ChannelArgs.str(@args, ChannelArgs::LB_POLICY_NAME, 'pick_first')
        unless LB_POLICIES.key?(@lb_policy_name)
          fail ArgumentError,
               "unsupported grpc.lb_policy_name #{@lb_policy_name.inspect}; " \
               "this implementation supports #{LB_POLICIES.keys.join(', ')}"
        end
        @client_idle_timeout = ChannelArgs.seconds(@args, ChannelArgs::CLIENT_IDLE_TIMEOUT_MS)
        @http2_max_pings_without_data = ChannelArgs.int(
          @args, ChannelArgs::HTTP2_MAX_PINGS_WITHOUT_DATA,
          Connection::DEFAULT_MAX_PINGS_WITHOUT_DATA)
        @http2_min_time_between_pings =
          ChannelArgs.seconds(@args, ChannelArgs::HTTP2_MIN_TIME_BETWEEN_PINGS_MS)
        @http2_max_ping_strikes = ChannelArgs.int(
          @args, ChannelArgs::HTTP2_MAX_PING_STRIKES,
          Connection::DEFAULT_MAX_PING_STRIKES)
        @http2_bdp_probe = !ChannelArgs.int(@args, ChannelArgs::HTTP2_BDP_PROBE, 1).zero?
        @http2_lookahead_bytes = ChannelArgs.int(
          @args, ChannelArgs::HTTP2_LOOKAHEAD_BYTES,
          Connection::DEFAULT_LOOKAHEAD_BYTES)
        @http2_max_frame_size = @args[ChannelArgs::HTTP2_MAX_FRAME_SIZE]
        @http2_write_buffer_size = @args[ChannelArgs::HTTP2_WRITE_BUFFER_SIZE]
        @per_message_compression = !ChannelArgs.int(
          @args, ChannelArgs::PER_MESSAGE_COMPRESSION, 1
        ).zero?
        @inhibit_health_checking = !ChannelArgs.int(
          @args, ChannelArgs::INHIBIT_HEALTH_CHECKING, 0
        ).zero?
      end

      def initialize_copy(_other)
        fail TypeError,
             'Copy initialization of GRPC::Core::Channel is not supported'
      end

      def secure?
        !@credentials.nil?
      end

      # Whether grpc.per_message_compression is enabled (the default), read
      # by Call#op_send_message alongside a per-call WriteFlags::NO_COMPRESS
      # so a channel-wide "never compress" setting has the same effect as
      # asking for it on every message, without adding per-message work.
      def per_message_compression?
        @per_message_compression
      end

      def scheme
        secure? ? 'https' : 'http'
      end

      def authority
        @authority ||=
          ChannelArgs.str(@args, ChannelArgs::DEFAULT_AUTHORITY) ||
          ssl_target_override ||
          default_authority
      end

      def user_agent
        @user_agent ||= begin
          parts = [ChannelArgs.str(@args, ChannelArgs::PRIMARY_USER_AGENT)]
          parts << "grpc-ruby-core/#{GRPC::VERSION} (#{RUBY_ENGINE}-" \
                   "#{RUBY_VERSION}; kantan)"
          parts << ChannelArgs.str(@args, ChannelArgs::SECONDARY_USER_AGENT)
          parts.compact.reject(&:empty?).join(' ')
        end
      end

      # rubocop:disable Style/OptionalBooleanParameter -- C API signature
      def connectivity_state(try_to_connect = false)
        fail 'closed!' if @destroyed
        maybe_start_connect if try_to_connect
        @mu.synchronize { @state }
      end
      # rubocop:enable Style/OptionalBooleanParameter

      # Blocks until the state differs from +last_state+ or +deadline+ passes.
      #
      # @return [Boolean] true when the state changed in time
      def watch_connectivity_state(last_state, deadline)
        fail 'closed!' if @destroyed
        unless last_state.is_a?(Integer)
          fail TypeError,
               'bad type for last_state. want a GRPC::Core::ChannelState constant'
        end
        limit = monotonic_from(deadline)
        @mu.synchronize do
          loop do
            return true if @state != last_state
            remaining = limit - RpcStream.now
            return false if remaining <= 0
            @cv.wait(@mu, remaining)
          end
        end
      end

      def create_call(parent, mask, method, host, deadline)
        fail 'closed!' if @destroyed
        Call.client(channel: self, method: method, host: host,
                    deadline: deadline, parent: parent, mask: mask)
      end

      # Returns the MethodConfig from the service config that applies to
      # +method+ (e.g. "/pkg.Svc/Method"), or nil when there is no service
      # config or nothing in it applies.
      def method_config(method)
        effective_service_config&.method_config(method)
      end

      # Whether retries are enabled for +method+. An explicit
      # grpc.enable_retries wins; absent that, gRPC turns retries on
      # exactly when the applicable method config carries a retry policy.
      def retries_enabled?(method)
        return @enable_retries_arg != 0 unless @enable_retries_arg.nil?
        !method_config(method)&.retry_policy.nil?
      end

      # Whether hedging is enabled for +method+. grpc.enable_retries's
      # override still turns both retries and hedging off together, since
      # hedging is gRPC's other response to a failed attempt; beyond that,
      # gRPC also requires grpc.experimental.enable_hedging (the flag that
      # actually turns hedging on) before a hedgingPolicy has any effect.
      # Neither arg set falls back to the same rule #retries_enabled? uses:
      # on exactly when the applicable method config carries the policy.
      def hedging_enabled?(method)
        return false if @enable_retries_arg&.zero?
        return false if @enable_hedging_arg&.zero?
        return @enable_retries_arg != 0 unless @enable_retries_arg.nil?
        return @enable_hedging_arg != 0 unless @enable_hedging_arg.nil?
        !method_config(method)&.hedging_policy.nil?
      end

      def destroy
        subchannels = nil
        outlier_timer = nil
        watch = nil
        @mu.synchronize do
          return nil if @destroyed
          @destroyed = true
          subchannels = @subchannels
          @subchannels = nil
          @lb_policy = nil
          outlier_timer = @outlier_detection_timer
          @outlier_detection_timer = nil
          watch = @resolver_watch
          @resolver_watch = nil
          @state = ConnectivityStates::FATAL_FAILURE
          @cv.broadcast
        end
        stop_outlier_detection_timer(outlier_timer)
        watch&.cancel
        subchannels&.each(&:close)
        nil
      end
      alias close destroy

      # Opens a stream for a new RPC, connecting first if necessary.
      #
      # @api private
      def open_stream(deadline: nil, hash_key: nil)
        connection = await_connection(deadline, hash_key)
        connection.open_rpc
      end

      # Drops the transport this channel inherited across a fork so that the
      # next RPC dials again. The synchronisation primitives are replaced
      # rather than taken, because a lock held at fork time is never released.
      #
      # @api private
      def reset_after_fork!
        subchannels = @subchannels
        @mu = Mutex.new
        @service_config_mu = Mutex.new
        @cv = ConditionVariable.new
        @subchannels = nil
        @lb_policy = nil
        @resolving = false
        @resolve_thread = nil
        @idle_timer = nil
        # Not woken/joined: a fork leaves no threads behind in the child,
        # only the ivar naming one that no longer exists. Likewise
        # @resolver_watch is dropped rather than #cancel-ed: cancelling
        # takes the (possibly inherited, possibly fork-locked) AdsConnection
        # mutex, and nothing in this child will ever call the callback
        # again anyway -- the ADS stream's thread did not survive the fork.
        @resolver_watch = nil
        @outlier_detection_timer = nil
        @last_error = nil
        @state = ConnectivityStates::IDLE unless @destroyed
        subchannels&.each(&:abandon)
        nil
      end

      private

      # Malformed JSON in grpc.service_config must fail channel construction
      # rather than silently run without the timeouts and retries it names.
      # The service config a resolver might supply over DNS is not parsed
      # here: unlike the channel argument, it takes a real (if usually
      # fast) DNS round trip, and #initialize must stay synchronous and
      # cheap the way #parse_target already is -- most channels never make
      # a call, and a construction that always paid for a TXT lookup would
      # tax every one of them for a feature only some ever use. See
      # #effective_service_config, which pays that cost, once, only for a
      # channel whose first call actually needs it.
      def build_service_config
        json = ChannelArgs.str(@args, ChannelArgs::SERVICE_CONFIG)
        json.nil? ? nil : ServiceConfig.new(json)
      end

      # The service config that applies: the grpc.service_config argument
      # if the caller gave one, otherwise the one #resolved_service_config
      # lazily fetches over DNS, exactly as gRPC orders the two.
      def effective_service_config
        @service_config || resolved_service_config
      end

      # Fetches and memoizes the "grpc_config=" TXT record the first time
      # any call asks for a method config, rather than in #initialize, so
      # that constructing a channel never blocks on DNS. Guarded by its own
      # mutex, distinct from @mu, so a concurrent connection attempt never
      # waits on this lookup or vice versa. A malformed resolver-supplied
      # service config is ignored rather than raised: unlike a bad
      # grpc.service_config argument, it was never something the caller
      # wrote, and there is no reasonable way to fail channel construction
      # over a record fetched well after the channel already exists.
      def resolved_service_config
        # Read the memo before taking the lock. This runs on every call, and
        # the lookup happens once, so holding a mutex for the other several
        # million reads serialised concurrent RPCs for nothing: it measured
        # 12 per cent on the eight-thread benchmark. The flag is written once
        # under the lock and only ever goes false to true, so a reader that
        # misses it merely takes the slow path and re-checks inside.
        return @resolved_service_config if @resolved_service_config_looked_up
        @service_config_mu.synchronize do
          next @resolved_service_config if @resolved_service_config_looked_up
          config = parse_resolved_service_config(resolved_service_config_json)
          @resolved_service_config = config
          @resolved_service_config_looked_up = true
          config
        end
      end

      def parse_resolved_service_config(json)
        return nil if json.nil?
        ServiceConfig.new(json)
      rescue ArgumentError
        nil
      end

      # grpc.service_config_disable_resolution stops the resolver from
      # supplying a service config at all -- not merged with, superseded
      # by -- the grpc.service_config argument, which #effective_service_config
      # already prefers and so never reaches this when it is set.
      def resolved_service_config_json
        return nil unless ChannelArgs.int(@args, ChannelArgs::SERVICE_CONFIG_DISABLE_RESOLUTION, 0).zero?
        Transport.service_config_json(@parsed_target)
      end

      # grpc.initial/min/max_reconnect_backoff_ms in milliseconds, converted
      # to the seconds every timer in this core works in.
      def build_backoff
        initial = ChannelArgs.int(@args, ChannelArgs::INITIAL_RECONNECT_BACKOFF_MS, 1_000) / 1000.0
        min = ChannelArgs.int(@args, ChannelArgs::MIN_RECONNECT_BACKOFF_MS, 1_000) / 1000.0
        max = ChannelArgs.int(@args, ChannelArgs::MAX_RECONNECT_BACKOFF_MS, 120_000) / 1000.0
        ReconnectBackoff.new(initial: initial, min: min, max: max)
      end

      def resolve_credentials(credentials)
        case credentials
        when Symbol
          unless credentials == :this_channel_is_insecure
            fail TypeError, 'bad creds symbol, want :this_channel_is_insecure'
          end
          nil
        when XdsChannelCredentials, ChannelCredentials
          @call_credentials = credentials.call_credentials
          credentials
        else
          fail TypeError,
               'bad creds, want ChannelCredentials or XdsChannelCredentials'
        end
      end

      def ssl_target_override
        ChannelArgs.str(@args, ChannelArgs::SSL_TARGET_NAME_OVERRIDE)
      end

      def default_authority
        return @parsed_target.path.to_s if @parsed_target.scheme == :unix
        return @parsed_target.host if @parsed_target.scheme == :xds
        "#{@parsed_target.host}:#{@parsed_target.port}"
      end

      def monotonic_from(deadline)
        seconds = TimeSpec.from(deadline).to_relative_seconds
        return RpcStream.now + (365 * 24 * 3600) if seconds.nil?
        RpcStream.now + seconds
      end

      # An IDLE channel connects immediately, as C-core does; the reconnect
      # backoff only throttles re-resolving after every address has failed
      # (see #schedule_reresolve_locked). Safe to call without holding
      # +@mu+: it takes the lock itself, in short, non-nested sections, so
      # that poking a Subchannel never happens while this channel's own
      # mutex is held -- a Subchannel may report a transition straight back
      # into #on_subchannel_state_changed, which would deadlock on a
      # recursive lock otherwise.
      def maybe_start_connect
        policy = @mu.synchronize do
          if @subchannels.nil?
            start_resolve_locked
            next nil
          end
          @lb_policy
        end
        return if policy.nil?
        policy.maybe_connect
        @mu.synchronize { transition_locked(policy.connectivity_state) unless @destroyed }
      end

      def start_resolve_locked
        return if @resolving
        @resolving = true
        transition_locked(ConnectivityStates::CONNECTING)
        @resolve_thread = Thread.new { resolve_worker }
        @resolve_thread.name = 'grpc-resolve'
      end

      # Runs the DNS lookup off the lock, exactly as dialing a socket always
      # has, since a slow resolver must not stall every other channel
      # operation. #effective_health_check_service_name is resolved here
      # too, off the lock, for the same reason #effective_service_config
      # itself defers a resolver-supplied config's DNS TXT lookup out of
      # #initialize: this thread is already paying for one DNS round trip,
      # and every Subchannel #build_subchannels_locked is about to create
      # needs the answer before it can decide whether to health-check.
      def resolve_worker
        addresses = Transport.resolve_addresses(@parsed_target, @args)
        start_resolver_watch_once
        health_check_service_name = effective_health_check_service_name
        outlier_detection_config = effective_service_config&.outlier_detection
        policy = @mu.synchronize do
          @resolving = false
          next nil if @destroyed
          build_subchannels_locked(addresses, health_check_service_name, outlier_detection_config)
          @lb_policy
        end
        policy&.maybe_connect
        @mu.synchronize { transition_locked(policy.connectivity_state) unless @destroyed || policy.nil? }
      rescue StandardError => e
        @mu.synchronize do
          @resolving = false
          next if @destroyed
          @last_error = e
          transition_locked(ConnectivityStates::TRANSIENT_FAILURE)
          schedule_reresolve_locked
        end
      end

      # Registers for a resolver push exactly once per channel: an xds:
      # target's Transport.watch_addresses subscribes with XdsClient
      # (which may touch its own request queue/thread); tcp:/unix: get
      # Transport's no-op handle. Called from #resolve_worker's own
      # thread, off @mu, for the same reason the lookup above already is
      # -- only the ivar itself is briefly locked, and #resolve_worker
      # never runs two at a time (guarded by @resolving), so nothing else
      # writes @resolver_watch concurrently except #destroy.
      def start_resolver_watch_once
        return if @mu.synchronize { !@resolver_watch.nil? || @destroyed }
        watch = Transport.watch_addresses(@parsed_target, @args) { |addresses| apply_resolver_push(addresses) }
        @mu.synchronize do
          if @destroyed
            watch.cancel
          else
            @resolver_watch = watch
          end
        end
      end

      # Called by the handle #start_resolver_watch_once registered,
      # from whichever thread XdsClient::AdsConnection delivers a
      # control-plane push on -- never while that connection's own lock
      # is held (see AdsConnection#handle_response) -- so reconciling
      # here is as free to poke a Subchannel as #maybe_start_connect
      # already is, off @mu. A push that arrives before the first
      # #resolve_worker has built @subchannels, or after #destroy, is
      # dropped: the former's own resolve is still in flight and will
      # pick up a fresher state itself, and the latter has nothing left
      # to reconcile into.
      def apply_resolver_push(addresses)
        health_check_service_name = effective_health_check_service_name
        outlier_detection_config = effective_service_config&.outlier_detection
        policy, stale, stale_timer = @mu.synchronize do
          next [nil, nil, nil] if @destroyed || @subchannels.nil?
          stale, stale_timer = reconcile_subchannels_locked(addresses, health_check_service_name, outlier_detection_config)
          [@lb_policy, stale, stale_timer]
        end
        return if policy.nil?
        stop_outlier_detection_timer(stale_timer)
        stale.each(&:close)
        policy.maybe_connect
        @mu.synchronize { transition_locked(policy.connectivity_state) unless @destroyed }
      end

      # grpc.inhibit_health_checking turns the feature off outright;
      # otherwise the applicable service config's healthCheckConfig names
      # the service to watch, or nil for none, exactly as
      # #effective_service_config already orders grpc.service_config ahead
      # of whatever a resolver supplied.
      def effective_health_check_service_name
        return nil if @inhibit_health_checking
        effective_service_config&.health_check_config&.service_name
      end

      # The very first resolve for this channel: every address is new, so
      # every Subchannel is too.
      def build_subchannels_locked(addresses, health_check_service_name, config)
        @subchannels = addresses.map { |address| new_subchannel(address, health_check_service_name) }
        install_lb_policy_locked(config)
      end

      # Called with @mu held to fold a resolver push into the live
      # subchannel set -- unlike #build_subchannels_locked (the very
      # first resolve, and the full teardown/rebuild
      # #schedule_reresolve_locked does after every address has failed),
      # this keeps the Subchannel for every address still named, so a
      # working connection is never dropped and no in-flight RPC on it is
      # disturbed, and only closes the ones whose address disappeared.
      # @lb_policy is always rebuilt fresh even though its class may be
      # unchanged: ring_hash and weighted_round_robin bake their
      # ring/weight schedule into the constructor from the subchannel
      # list they are handed, so #install_lb_policy_locked is already the
      # cheapest way to fold in a changed set. The stale subchannels and
      # any outlier-detection timer they leave behind are returned rather
      # than closed/stopped here -- neither may be touched while @mu is
      # held, exactly like #schedule_reresolve_locked's own teardown.
      def reconcile_subchannels_locked(addresses, health_check_service_name, config)
        by_key = @subchannels.each_with_object({}) { |sc, h| h[address_key(sc.address)] = sc }
        @subchannels = addresses.map do |address|
          by_key.delete(address_key(address)) || new_subchannel(address, health_check_service_name)
        end
        stale = by_key.values
        stale_timer = @outlier_detection_timer
        @outlier_detection_timer = nil
        install_lb_policy_locked(config)
        [stale, stale_timer]
      end

      # The identity a Subchannel is kept or dropped by across a push:
      # scheme/host/port/path, not #weight or #lrs_counter, which an EDS
      # rebalance can change for the very same physical endpoint without
      # that endpoint's connection needing to be torn down and redialed.
      def address_key(address)
        [address.scheme, address.host, address.port, address.path]
      end

      # Wraps the child LB_POLICIES entry in an OutlierDetectionPolicy, and
      # starts the one timer that drives it, exactly when +config+ is
      # non-nil -- i.e. the applicable service config carried an
      # outlierDetection object. Called with @mu held and
      # @outlier_detection_timer already nil: #build_subchannels_locked's
      # caller never set one, and #reconcile_subchannels_locked's own
      # caller clears it (returning the prior epoch's timer for the
      # caller to stop off @mu, since neither may be touched while it is
      # held) before calling here.
      def install_lb_policy_locked(config)
        child = LB_POLICIES.fetch(@lb_policy_name).new(@subchannels, @args)
        if config.nil?
          @lb_policy = child
        else
          @lb_policy = OutlierDetectionPolicy.new(@subchannels, child, config)
          start_outlier_detection_timer_locked(@lb_policy, config.interval)
        end
      end

      def new_subchannel(address, health_check_service_name)
        subchannel = Subchannel.new(address, dial: method(:build_connection_for),
                                             on_state_change: method(:on_subchannel_state_changed),
                                             health_check_service_name: health_check_service_name,
                                             health_backoff_factory: method(:build_backoff))
        # Only an EDS-resolved xds address carries a Target#lrs_counter
        # (see XdsClient::AdsConnection#target_of); every other resolver
        # leaves it nil, so this is a no-op for dns:/unix:/plain targets.
        subchannel.lrs_counter = address.lrs_counter if address.respond_to?(:lrs_counter) && address.lrs_counter
        subchannel
      end

      # Dials +address+, one of the addresses #resolve_addresses returned
      # for @parsed_target. TLS hostname verification and any HTTP CONNECT
      # proxy authority still use @parsed_target -- the name the caller
      # asked for -- never the resolved address.
      def build_connection_for(address, on_close)
        socket, peer, peer_cert = Transport.connect(
          @parsed_target, @credentials, ssl_target_override,
          address: address, args: @args)
        connection = Connection.new(
          socket, peer: peer, client: true, peer_cert: peer_cert,
                  max_receive_message_length: @max_receive_message_length,
                  max_send_message_length: @max_send_message_length,
                  keepalive_time: @keepalive_time,
                  keepalive_timeout: @keepalive_timeout,
                  keepalive_permit_without_calls: @keepalive_permit_without_calls,
                  client_idle_timeout: @client_idle_timeout,
                  max_pings_without_data: @http2_max_pings_without_data,
                  min_time_between_pings: @http2_min_time_between_pings,
                  max_ping_strikes: @http2_max_ping_strikes,
                  on_close: on_close)
        connection.start
        # A completed TCP connect is not a usable channel: the peer may have
        # queued the socket and never serviced it. READY means the HTTP/2
        # handshake finished.
        begin
          connection.await_handshake(Transport::DEFAULT_CONNECT_TIMEOUT)
        rescue StandardError => e
          connection.close
          raise e
        end
        connection
      end

      # Called by a Subchannel, outside its own lock, after a transition it
      # reported asynchronously (never while this channel's own lock is
      # held -- see #maybe_start_connect). Recomputes the aggregate: READY
      # if any subchannel is, CONNECTING if any is, TRANSIENT_FAILURE only
      # once every one has failed. A nil @lb_policy means this channel has
      # already re-resolved past the subchannel reporting in; ignore it.
      #
      # +subchannel+ landing in IDLE while a sibling is still alive means
      # a previously live connection just closed (e.g. a GOAWAY, or the
      # peer dropping the socket) while that sibling keeps carrying
      # traffic. #await_connection only calls #maybe_start_connect, which
      # would otherwise redial it, when picking fails outright; as long
      # as the sibling keeps #pick succeeding, this one would sit IDLE
      # forever. Redialing it immediately here is what keeps every
      # resolved address in use, not just whichever ones happened to
      # answer last.
      #
      # Deliberately gated on a sibling being alive, not merely on the
      # aggregate being something other than TRANSIENT_FAILURE: a lone
      # subchannel (pick_first, or any policy with exactly one address)
      # going straight from READY to IDLE aggregates to IDLE, never
      # TRANSIENT_FAILURE, so that weaker guard still redialed it here,
      # immediately, racing the exact backoff/reresolve path
      # #schedule_reresolve_locked -> #await_connection already owns for
      # "every address just failed" -- stamping a fresh @last_error from
      # a retry nothing asked for, which #pick_or_error_locked could then
      # hand a later, unrelated caller instead of that caller's own
      # attempt. Requiring an alive sibling excludes exactly that case.
      def on_subchannel_state_changed(subchannel)
        redial = false
        @mu.synchronize do
          next if @destroyed || @lb_policy.nil?
          new_state = @lb_policy.connectivity_state
          if new_state == ConnectivityStates::TRANSIENT_FAILURE
            @last_error = @lb_policy.last_error
            schedule_reresolve_locked
          end
          redial = subchannel.state == ConnectivityStates::IDLE && @subchannels.any?(&:alive?)
          transition_locked(new_state)
        end
        subchannel.maybe_connect if redial
      end

      # Every resolved address has failed. Reuses the same ReconnectBackoff
      # sequence a single connection attempt already advances -- rather than
      # inventing a second backoff scheme -- then re-resolves so a DNS
      # change, or an address that is reachable again, gets picked up.
      # Subchannels are closed after the lock is released, since #close
      # reports back through #on_subchannel_state_changed.
      def schedule_reresolve_locked
        return if @idle_timer
        delay = @backoff.next_delay
        @idle_timer = Thread.new do
          sleep delay
          subchannels, outlier_timer = @mu.synchronize do
            @idle_timer = nil
            next [nil, nil] if @destroyed
            next [nil, nil] unless @lb_policy.connectivity_state == ConnectivityStates::TRANSIENT_FAILURE
            stale = @subchannels
            timer = @outlier_detection_timer
            @subchannels = nil
            @lb_policy = nil
            @outlier_detection_timer = nil
            transition_locked(ConnectivityStates::IDLE)
            [stale, timer]
          end
          stop_outlier_detection_timer(outlier_timer)
          subchannels&.each(&:close)
        end
        @idle_timer.name = 'grpc-reresolve'
      end

      def start_outlier_detection_timer_locked(policy, interval)
        @outlier_detection_timer = Thread.new { outlier_detection_worker(policy, interval) }
        @outlier_detection_timer.name = 'grpc-outlier-detection'
      end

      # Runs until +policy+ stops being @lb_policy -- torn down by #destroy
      # or #schedule_reresolve_locked's re-resolve, both of which also call
      # #stop_outlier_detection_timer to wake this early rather than making
      # ejected addresses wait out a stale timer's last +interval+.
      def outlier_detection_worker(policy, interval)
        until @mu.synchronize { !@lb_policy.equal?(policy) }
          sleep interval
          break if @mu.synchronize { !@lb_policy.equal?(policy) }
          policy.evaluate
        end
      end

      # The loop above wakes on its own interval, so tearing it down only
      # has to clear @lb_policy (already done by the caller) and wait for
      # it to notice; #wakeup cuts that wait down from the full interval.
      def stop_outlier_detection_timer(thread)
        return if thread.nil? || thread == Thread.current
        thread.wakeup if thread.alive?
        thread.join(1)
      end

      # READY means some subchannel just dialed successfully, so the next
      # failure should back off from grpc.initial_reconnect_backoff_ms
      # again rather than continuing to grow from wherever it left off.
      def transition_locked(state)
        return if @state == state
        @backoff.reset if state == ConnectivityStates::READY
        @state = state
        @cv.broadcast
      end

      # Blocks until a live connection exists, raising the connect error when
      # the attempt fails so that Call can turn it into an UNAVAILABLE status.
      def await_connection(deadline, hash_key = nil)
        limit = deadline || (RpcStream.now + Transport::DEFAULT_CONNECT_TIMEOUT)
        loop do
          kind, value = @mu.synchronize { pick_or_error_locked(hash_key) }
          return value.connection if kind == :ready
          raise value if kind == :error
          maybe_start_connect
          remaining = limit - RpcStream.now
          fail Connection::Closed, "connect timed out to #{@target}" if remaining <= 0
          @mu.synchronize { @cv.wait(@mu, [remaining, AWAIT_POLL_INTERVAL].min) }
        end
      end

      # Must be called with @mu held. Returns the subchannel to use, the error
      # to raise, or nothing when the caller should wait and look again.
      def pick_or_error_locked(hash_key)
        fail Connection::Closed, 'channel closed' if @destroyed
        subchannel = @lb_policy&.pick(hash_key)
        return [:ready, subchannel] if subchannel
        return nil unless @state == ConnectivityStates::TRANSIENT_FAILURE && @last_error
        error = @last_error
        @last_error = nil
        [:error, error]
      end
    end
  end
end
