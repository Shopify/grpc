# frozen_string_literal: true

# Copyright 2026 gRPC authors.
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
    class XdsClient
      # One management server's wire connection: a single persistent Channel
      # (so channelz has something to report for as long as this server is in
      # use -- see #status_ok? and #close), the ADS bidi stream (LDS/RDS/CDS/
      # EDS) that stream runs on, and -- lazily, only if some Cluster this
      # connection hears about actually asks for it -- that same server's LRS
      # stream. XdsClient owns one of these per distinct server_uri (see
      # #connection_for); a process with only the default, unfederated
      # bootstrap and no fallback server has exactly one.
      #
      # This class knows nothing about listeners, route configs, clusters or
      # the dependency chain between them -- gRFC A47 (federation) and A71
      # (fallback) both route by an *authority*, and one management server
      # can serve resources for several authorities (or none at all, if every
      # authority's traffic has fallen forward past it). That routing, the
      # per-authority ordered server list, and the resource cache all belong
      # to XdsClient itself; this class only multiplexes (type_url, name)
      # subscriptions onto one wire connection and reports back what came of
      # them.
      #
      # @api private
      class AdsConnection
        TYPE_LISTENER = XdsClient::TYPE_LISTENER
        TYPE_ROUTE = XdsClient::TYPE_ROUTE
        TYPE_CLUSTER = XdsClient::TYPE_CLUSTER
        TYPE_ENDPOINT = XdsClient::TYPE_ENDPOINT

        RESOURCE_CLASSES = {
          TYPE_LISTENER => Envoy::Config::Listener::V3::Listener,
          TYPE_ROUTE => Envoy::Config::Route::V3::RouteConfiguration,
          TYPE_CLUSTER => Envoy::Config::Cluster::V3::Cluster,
          TYPE_ENDPOINT => Envoy::Config::Endpoint::V3::ClusterLoadAssignment
        }.freeze

        ADS_METHOD = '/envoy.service.discovery.v3.AggregatedDiscoveryService/StreamAggregatedResources'
        LRS_METHOD = '/envoy.service.load_stats.v3.LoadReportingService/StreamLoadStats'

        INITIAL_BACKOFF = 1
        MAX_BACKOFF = 120
        # How long an idle connection (nothing new to subscribe/report,
        # nothing ACK/NACK-worthy pending) waits before resending one
        # already-current subscription (ADS) or checking whether an LRS
        # report is due (LRS), purely so a dead management server is
        # discovered in bounded time instead of only on the next real
        # change. See #keepalive_request_locked and #pump_lrs_requests.
        KEEPALIVE_INTERVAL = 3
        QUEUE_POLL_INTERVAL = 0.1
        # How long the status-watch thread waits, at most, between checks
        # that #close has not been asked for -- it otherwise blocks in
        # Channel#watch_connectivity_state, which #close's Channel#destroy
        # wakes immediately, so this bound is only for a #close race with
        # the very first iteration.
        STATUS_POLL_INTERVAL = 5

        attr_reader :server_uri, :dedup_key

        def initialize(server, node, on_resource:, on_healthy:, on_status_change:)
          @server_uri = server.server_uri
          @dedup_key = [server.server_uri, server.channel_creds_type]
          @channel_creds = channel_creds_for(server.channel_creds_type)
          @node = node
          @on_resource = on_resource
          @on_healthy = on_healthy
          @on_status_change = on_status_change

          @mu = Mutex.new
          @cv = ConditionVariable.new
          @closed = false

          # Per resource type (a TYPE_* constant): the resource names this
          # connection has subscribed to, the last version_info ACKed
          # (persists across a reconnect), and the last nonce seen on the
          # current stream (reset to '' on every reconnect).
          @subscribed = Hash.new { |h, k| h[k] = {} }
          @versions = Hash.new('')
          @nonces = Hash.new('')

          # LRS: clusters this connection has seen a Cluster#lrs_server
          # pointing at "self" for, their running counters (created lazily,
          # kept across reports so a cluster with no traffic yet still
          # gets a zeroed entry rather than crashing a Hash#fetch), and the
          # server's most recently stated interval/cluster list -- nil
          # until the first LoadStatsResponse arrives, at which point
          # #pump_lrs_requests starts actually reporting.
          @lrs_clusters = {}
          @lrs_counters = Hash.new { |h, k| h[k] = LrsCallCounter.new }
          @lrs_interval = nil
          @lrs_report_clusters = []
          @lrs_thread = nil
          @lrs_request_queue = nil
          @lrs_backoff = ReconnectBackoff.new(initial: INITIAL_BACKOFF, min: INITIAL_BACKOFF, max: MAX_BACKOFF)

          # One persistent Channel for the life of this connection -- see
          # #status_ok? (gRFC A71 fallback triggers off its connectivity
          # state) and the class comment above. Every ADS/LRS stream
          # attempt below rides this same Channel (via
          # ClientStub#channel_override) rather than opening a fresh one,
          # so channelz has something to report between reconnect attempts
          # and #close is the only thing that ever tears it down.
          @channel = Channel.new(@server_uri, {}, @channel_creds)

          @request_queue = nil
          @backoff = ReconnectBackoff.new(initial: INITIAL_BACKOFF, min: INITIAL_BACKOFF, max: MAX_BACKOFF)
          @stream_thread = Thread.new do
            Thread.current.name = 'xds-ads'
            drive_stream
          end
          @status_thread = Thread.new do
            Thread.current.name = 'xds-status'
            watch_status
          end
        end

        # Subscribes (if not already) to +name+ of +type_url+, sending the
        # request immediately if the ADS stream is up.
        def subscribe(type_url, name)
          @mu.synchronize do
            next if @subscribed[type_url].key?(name)
            @subscribed[type_url][name] = true
            send_request_locked(type_url)
          end
        end

        # Whether this connection's Channel currently looks usable -- gRFC
        # A71's fallback trigger. A freshly created Channel is IDLE, not
        # TRANSIENT_FAILURE, so a connection is presumed healthy until
        # proven otherwise, exactly like a freshly added fallback server in
        # C-core's MaybeFallbackLocked.
        def status_ok?
          @channel.connectivity_state(false) != ConnectivityStates::TRANSIENT_FAILURE
        end

        # Notes that +cluster+ wants load reporting from this server (its
        # lrs_server points at "self") and, the first time any cluster on
        # this connection does, starts the LRS stream.
        def note_lrs(cluster)
          return unless cluster.lrs_server&.config_source_specifier == :self
          @mu.synchronize do
            next if @lrs_clusters.key?(cluster.name)
            @lrs_clusters[cluster.name] = true
            ensure_lrs_stream_locked
          end
        end

        # nil (LRS never requested by any cluster on this connection) or
        # not yet requested for +cluster_name+ specifically: no counter, so
        # the resolved Target carries none and Subchannel/Connection never
        # wire up anything for it.
        def lrs_counter_for(cluster_name)
          @mu.synchronize { @lrs_clusters.key?(cluster_name) ? @lrs_counters[cluster_name] : nil }
        end

        def close
          ads_thread, lrs_thread, status_thread = @mu.synchronize do
            return if @closed
            @closed = true
            @cv.broadcast
            @request_queue&.push(:stop)
            @lrs_request_queue&.push(:stop)
            [@stream_thread, @lrs_thread, @status_thread]
          end
          # Wakes both the ADS/LRS streams' next write attempt (a call on a
          # destroyed Channel raises) and the status thread's blocked
          # #watch_connectivity_state, and drops this server's channelz
          # entry.
          @channel.close
          ads_thread.wakeup if ads_thread.alive?
          ads_thread.join(5)
          if lrs_thread
            lrs_thread.wakeup if lrs_thread.alive?
            lrs_thread.join(5)
          end
          status_thread.join(5)
          nil
        end

        private

        # ---- Wire-format channel creds for the management-server channel.
        # SDS-provisioned mTLS to the management server itself is out of
        # scope; "insecure" is honoured exactly, anything else falls back
        # to a plain TLS ChannelCredentials using the system trust store.
        def channel_creds_for(type)
          type == 'insecure' ? :this_channel_is_insecure : ChannelCredentials.new
        end

        # ---- Connectivity-state watch: reports this connection's health
        # to XdsClient so it can trigger (or revert) fallback without
        # waiting for the next #subscribe.

        def watch_status
          last = @channel.connectivity_state(false)
          until @mu.synchronize { @closed }
            # An absolute Time, as Channel#watch_connectivity_state takes
            # its deadline: a monotonic reading would be read as epoch
            # seconds, already past, and this loop would spin.
            changed = @channel.watch_connectivity_state(last, Time.now + STATUS_POLL_INTERVAL)
            next unless changed
            current = @channel.connectivity_state(false)
            next if current == last
            last = current
            @on_status_change.call(self, current != ConnectivityStates::TRANSIENT_FAILURE)
          end
        rescue RuntimeError
          # #close already destroyed @channel; connectivity_state raises
          # "closed!" for any call after that, which just means this
          # thread's work is done.
          nil
        end

        # ---- Subscription bookkeeping and request sending.

        def build_request_locked(type_url, error_detail: nil)
          request = Envoy::Service::Discovery::V3::DiscoveryRequest.new(
            version_info: @versions[type_url],
            node: @node,
            resource_names: @subscribed[type_url].keys,
            type_url: type_url,
            response_nonce: @nonces[type_url]
          )
          request.error_detail = error_detail unless error_detail.nil?
          request
        end

        def send_request_locked(type_url, error_detail: nil)
          return if @request_queue.nil?
          @request_queue.push(build_request_locked(type_url, error_detail: error_detail))
        end

        # A response the client already ACKed carries nothing new to send,
        # so an idle steady-state connection can go indefinitely long
        # between writes. That is invisible to the *peer* half of the
        # connection -- bidi_call's write loop only discovers the stream
        # has died the next time it actually attempts to send -- so an
        # idle connection whose management server vanishes would otherwise
        # never be noticed, and #close's join on the stream thread would
        # hang forever waiting for a response that is never coming.
        # Resending one already-subscribed type's current state is a
        # harmless no-op to a well-behaved server and, to a dead one, the
        # write that finally raises.
        def keepalive_request_locked
          type_url = RESOURCE_CLASSES.each_key.find { |t| !@subscribed[t].empty? }
          return nil if type_url.nil?
          build_request_locked(type_url)
        end

        # ---- Response processing: decode, ACK or NACK, report upward.

        class DecodeError < StandardError; end

        def handle_response(response)
          type_url = response.type_url
          decoded = decode_resources(type_url, response.resources)
          @mu.synchronize do
            @nonces[type_url] = response.nonce
            @versions[type_url] = response.version_info
            send_request_locked(type_url)
            @cv.broadcast
          end
          # Off @mu: XdsClient's own lock must never be taken while this
          # connection's lock is held, mirroring the rule Channel itself
          # follows for its own lock in #maybe_start_connect. A response
          # that accepted proves the connection alive even if it named no
          # resources this authority still cares about, so #on_healthy
          # (gRFC A71's "fall forward") runs unconditionally; #on_resource
          # then updates whichever authorities' caches actually subscribed
          # to what came back.
          @on_healthy.call(self)
          @on_resource.call(self, type_url, decoded)
        rescue DecodeError => e
          @mu.synchronize do
            @nonces[type_url] = response.nonce
            status = Google::Rpc::Status.new(code: StatusCodes::INVALID_ARGUMENT, message: e.message)
            send_request_locked(type_url, error_detail: status)
          end
        end

        def decode_resources(type_url, anys)
          klass = RESOURCE_CLASSES.fetch(type_url) { fail DecodeError, "unsupported resource type #{type_url}" }
          anys.to_h do |any|
            msg = klass.decode(any.value)
            [type_url == TYPE_ENDPOINT ? msg.cluster_name : msg.name, msg]
          end
        rescue Google::Protobuf::ParseError => e
          raise DecodeError, "malformed #{type_url} resource: #{e.message}"
        end

        # ---- The ADS stream itself: connect, drive request/response, and
        # on any failure back off and reconnect, resending every
        # subscription this connection has accumulated (with an empty
        # nonce -- nonces do not survive a stream -- but the last accepted
        # version_info, which does).

        def drive_stream
          until @mu.synchronize { @closed }
            begin
              run_stream_once
              @backoff.reset
            rescue StandardError => e
              GRPC.logger.debug("xDS ADS stream to #{@server_uri} failed: #{e.class}: #{e.message}")
            end
            break if @mu.synchronize { @closed }
            sleep(@backoff.next_delay)
          end
        end

        def run_stream_once
          require_relative '../generic/client_stub'
          queue = Queue.new
          @mu.synchronize do
            @nonces.clear
            @request_queue = queue
            RESOURCE_CLASSES.each_key { |type_url| send_request_locked(type_url) unless @subscribed[type_url].empty? }
          end
          # Rides the one persistent @channel (see #initialize) rather than
          # opening a fresh Channel per attempt -- ClientStub#close below
          # is then a no-op on it, and channelz keeps reporting this
          # server's state across the reconnect.
          stub = GRPC::ClientStub.new(@server_uri, @channel_creds, channel_override: @channel)
          begin
            requests = Enumerator.new { |y| pump_requests(queue, y) }
            marshal = ->(msg) { msg.class.encode(msg) }
            unmarshal = ->(bytes) { Envoy::Service::Discovery::V3::DiscoveryResponse.decode(bytes) }
            responses = stub.bidi_streamer(ADS_METHOD, requests, marshal, unmarshal)
            responses.each { |response| handle_response(response) }
          ensure
            # #close's own :stop only reaches whichever attempt's queue is
            # still @request_queue; a stream that ends on its own (an
            # error, or the peer closing) needs *this* attempt's queue
            # told to stop too, or the write thread bidi_streamer started
            # for it keeps polling an orphaned queue forever -- one leaked
            # thread per reconnect, for as long as the process runs.
            queue.push(:stop)
            stub.close
          end
        ensure
          @mu.synchronize { @request_queue = nil if @request_queue.equal?(queue) }
        end

        # Feeds +y+ from +queue+, polling rather than blocking indefinitely
        # on an empty queue: see #keepalive_request_locked for why an idle
        # connection still needs to occasionally attempt a write.
        def pump_requests(queue, yielder)
          idle_since = RpcStream.now
          loop do
            req = queue.pop(true)
            break if req == :stop
            yielder << req
            idle_since = RpcStream.now
          rescue ThreadError
            if RpcStream.now - idle_since >= KEEPALIVE_INTERVAL
              keepalive = @mu.synchronize { keepalive_request_locked }
              idle_since = RpcStream.now
              yielder << keepalive unless keepalive.nil?
            else
              sleep(QUEUE_POLL_INTERVAL)
            end
          end
        end

        # ---- LRS: opened lazily, the first time a Cluster's lrs_server
        # names this same management server ("self"), and driven with its
        # own reconnect loop exactly like the ADS stream above, over the
        # same persistent @channel.

        def ensure_lrs_stream_locked
          return unless @lrs_thread.nil?
          @lrs_thread = Thread.new do
            Thread.current.name = 'xds-lrs'
            drive_lrs_stream
          end
        end

        def drive_lrs_stream
          until @mu.synchronize { @closed }
            begin
              run_lrs_stream_once
              @lrs_backoff.reset
            rescue StandardError => e
              GRPC.logger.debug("xDS LRS stream to #{@server_uri} failed: #{e.class}: #{e.message}")
            end
            break if @mu.synchronize { @closed }
            # A fresh stream restarts the handshake from scratch: the
            # server tells it which clusters and interval to report at
            # all over again, so a dropped LRS stream must not go on
            # reporting against a config that stream never actually saw.
            @mu.synchronize { @lrs_interval = nil }
            sleep(@lrs_backoff.next_delay)
          end
        end

        def run_lrs_stream_once
          require_relative '../generic/client_stub'
          queue = Queue.new
          @mu.synchronize { @lrs_request_queue = queue }
          stub = GRPC::ClientStub.new(@server_uri, @channel_creds, channel_override: @channel)
          begin
            queue.push(Envoy::Service::LoadStats::V3::LoadStatsRequest.new(node: @node))
            requests = Enumerator.new { |y| pump_lrs_requests(queue, y) }
            marshal = ->(msg) { msg.class.encode(msg) }
            unmarshal = ->(bytes) { Envoy::Service::LoadStats::V3::LoadStatsResponse.decode(bytes) }
            responses = stub.bidi_streamer(LRS_METHOD, requests, marshal, unmarshal)
            responses.each { |response| handle_lrs_response(response) }
          ensure
            queue.push(:stop)
            stub.close
          end
        ensure
          @mu.synchronize { @lrs_request_queue = nil if @lrs_request_queue.equal?(queue) }
        end

        # The server names which clusters it wants reports for (a subset
        # of the ones this connection told it about via the initial,
        # stats-less request) and how often; #pump_lrs_requests starts
        # actually sending reports once @lrs_interval is set.
        def handle_lrs_response(response)
          @mu.synchronize do
            interval = response.load_reporting_interval
            @lrs_interval = interval.seconds.to_f + (interval.nanos / 1_000_000_000.0) unless interval.nil?
            @lrs_report_clusters = response.clusters.to_a
          end
        end

        # Mirrors #pump_requests: drains +queue+ (the initial
        # identification, here), and once @lrs_interval is known, sends a
        # fresh report every time that many seconds pass with nothing else
        # to send.
        def pump_lrs_requests(queue, yielder)
          last_report = RpcStream.now
          loop do
            req = queue.pop(true)
            break if req == :stop
            yielder << req
            last_report = RpcStream.now
          rescue ThreadError
            interval = @mu.synchronize { @lrs_interval }
            if interval && RpcStream.now - last_report >= interval
              yielder << build_lrs_report_locked
              last_report = RpcStream.now
            else
              sleep(QUEUE_POLL_INTERVAL)
            end
          end
        end

        def build_lrs_report_locked
          @mu.synchronize do
            cluster_stats = @lrs_report_clusters.map { |name| cluster_stats_for_locked(name) }
            Envoy::Service::LoadStats::V3::LoadStatsRequest.new(node: @node, cluster_stats: cluster_stats)
          end
        end

        def cluster_stats_for_locked(name)
          issued, success, failure, in_progress = @lrs_counters[name].snapshot!
          Envoy::Config::Endpoint::V3::ClusterStats.new(
            cluster_name: name,
            upstream_locality_stats: [
              Envoy::Config::Endpoint::V3::UpstreamLocalityStats.new(
                total_issued_requests: issued,
                total_successful_requests: success,
                total_error_requests: failure,
                total_requests_in_progress: in_progress
              )
            ]
          )
        end
      end
    end
  end
end
