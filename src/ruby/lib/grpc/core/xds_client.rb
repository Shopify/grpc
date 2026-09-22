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

require_relative 'reconnect_backoff'
require_relative 'rpc_stream'
require_relative 'xds_bootstrap'

# The generated message classes live under src/ruby/pb/xds (see
# generate_xds_pb.sh) rather than src/ruby/pb, because their own `require`
# by the test .proto fixtures would risk a name collision. Prepending this
# directory to the load path is the whole integration cost.
XDS_PB_DIR = File.expand_path('../../../pb/xds', __dir__)
$LOAD_PATH.unshift(XDS_PB_DIR) unless $LOAD_PATH.include?(XDS_PB_DIR)

require 'envoy/config/cluster/v3/cluster_pb'
require 'envoy/config/core/v3/base_pb'
require 'envoy/config/endpoint/v3/endpoint_pb'
require 'envoy/config/endpoint/v3/endpoint_components_pb'
require 'envoy/config/endpoint/v3/load_report_pb'
require 'envoy/config/listener/v3/listener_pb'
require 'envoy/config/listener/v3/api_listener_pb'
require 'envoy/config/route/v3/route_pb'
require 'envoy/config/route/v3/route_components_pb'
require 'envoy/extensions/filters/network/http_connection_manager/v3/http_connection_manager_pb'
require 'envoy/service/discovery/v3/discovery_pb'
require 'envoy/service/load_stats/v3/lrs_pb'
require 'google/protobuf/any_pb'
require 'google/protobuf/duration_pb'
require 'google/protobuf/struct_pb'
require 'google/rpc/status_pb'

module GRPC
  module Core
    # A client for the Aggregated Discovery Service (ADS) and, per cluster,
    # the Load Reporting Service (LRS). There is exactly one instance per
    # process (see .instance) because there is exactly one bootstrap
    # (GRPC_XDS_BOOTSTRAP is a process-wide environment variable) --
    # concurrent xds:// channels for different resource names, and even for
    # different xDS federation authorities, share this one object.
    #
    # Routing (gRFC A47): every resource subscription -- not just the
    # top-level Listener a target names -- is routed by the *authority of
    # its own name*. An "xdstp://<authority>/..." name routes to that
    # authority's servers (#resource_authority, #authority_servers_for); a
    # plain name is "old style" and always routes to the top-level
    # xds_servers, regardless of which authority's Listener happened to
    # name it. This is what lets a Listener served by one authority name a
    # Cluster served by another (see ListenerChain).
    #
    # Fallback (gRFC A71): each authority tracks its own ordered list of
    # servers (#authority_servers_for) and how many of them are currently
    # in play (AuthorityState#channels, highest priority first, the last
    # entry always the one actually in use). A watched-but-uncached
    # resource on the active server's channel going unhealthy adds the next
    # server (#maybe_fallback_locked); any server in the list receiving a
    # response promotes it back to active and drops (and, once no other
    # authority needs it, closes) everything after it
    # (#handle_channel_healthy). See AdsConnection for the one persistent
    # Channel per physical server this all runs over.
    #
    # Out of scope: SDS/mTLS certificate provisioning, RBAC and
    # fault-injection filters, aggregate clusters, collection resources and
    # incremental xDS (needed for glob collections), weighted-locality
    # routing beyond flattening every healthy endpoint a cluster's
    # localities name, and ever unsubscribing a resource once subscribed
    # (a resource with no watchers left simply stops mattering, rather than
    # being told to the server or evicted from the cache).
    #
    # @api private
    class XdsClient
      Error = Class.new(StandardError)

      TYPE_LISTENER = 'type.googleapis.com/envoy.config.listener.v3.Listener'
      TYPE_ROUTE = 'type.googleapis.com/envoy.config.route.v3.RouteConfiguration'
      TYPE_CLUSTER = 'type.googleapis.com/envoy.config.cluster.v3.Cluster'
      TYPE_ENDPOINT = 'type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment'

      # Returned by #watch_endpoints. +cancel+ drops the subscription so a
      # destroyed Channel's callback is never invoked again; safe to call
      # more than once.
      Watch = Struct.new(:listener_chain, :id) do
        def cancel
          listener_chain.unwatch(id)
          nil
        end
      end

      DEFAULT_RESOLVE_TIMEOUT = 10

      class << self
        # Parses (and caches) the bootstrap. Called from
        # Transport.parse_target so a bad GRPC_XDS_BOOTSTRAP fails channel
        # construction instead of the first RPC.
        def bootstrap!
          @bootstrap_mu.synchronize { @bootstrap ||= XdsBootstrap.load }
        end

        # The one XdsClient for this process, built lazily on first
        # resolve; it opens no connection until something is actually
        # subscribed to (see #ensure_channels_locked).
        def instance
          @instance_mu.synchronize { @instance ||= new(bootstrap!) }
        end

        # @api private -- specs only, so a bad bootstrap in one example
        # cannot leak a memoized client (or its background threads) into
        # the next.
        def reset_for_testing!
          client = @instance_mu.synchronize do
            client = @instance
            @instance = nil
            client
          end
          client&.close
          @bootstrap_mu.synchronize { @bootstrap = nil }
        end
      end
      @bootstrap_mu = Mutex.new
      @instance_mu = Mutex.new

      # One authority's fallback state (gRFC A71): the ordered server list
      # it resolves against (top-level xds_servers for the +nil+, "old
      # style" authority), the ordered channels currently in play (a
      # prefix of +xds_servers+ translated 1:1 through #connection_for --
      # +channels.last+ is always the one actually in use), and the
      # resource cache every subscription and update goes through.
      AuthorityState = Struct.new(:xds_servers, :channels, :resources) do
        def initialize(xds_servers)
          super(xds_servers, [], Hash.new { |h, k| h[k] = {} })
        end
      end

      # One (type_url, name) cache entry: the decoded resource last
      # accepted (nil until the first one arrives), the AdsConnection it
      # came from (a Cluster needs this to find its own server's LRS
      # counter), and the watchers -- keyed by an opaque id so the same
      # ListenerChain re-subscribing the same name is idempotent -- to
      # notify when #value changes.
      ResourceEntry = Struct.new(:value, :connection, :watchers) do
        def initialize
          super(nil, nil, {})
        end
      end

      def initialize(config)
        @config = config
        @node = build_node(config.node)
        @listener_template = config.listener_resource_name_template
        @mu = Mutex.new
        @authorities = {}
        @listener_chains = {}
        @connections = {}
        @connection_refs = Hash.new(0)
        fail XdsBootstrap::Error, 'the xDS bootstrap config has no usable xds_servers entry' if config.servers.empty?
      end

      # Subscribes (if not already) to +listener_name+ and blocks until its
      # LDS -> RDS -> CDS -> EDS chain has resolved to a set of endpoints,
      # or +timeout+ seconds pass. +authority+ selects a federated (gRFC
      # A47) management server, already validated against the bootstrap's
      # "authorities" map by Transport.parse_target; nil (the common case)
      # resolves against the top-level xds_servers.
      #
      # @return [Array<Transport::Target>]
      def resolve_endpoints(listener_name, authority: nil, timeout: DEFAULT_RESOLVE_TIMEOUT)
        chain_for(listener_name, authority).resolve(timeout)
      end

      # Registers +block+ to be called with a fresh
      # Array<Transport::Target> every time a later control-plane push
      # changes +listener_name+'s resolved endpoints -- #resolve_endpoints's
      # initial pull is not repeated here. Routing mirrors
      # #resolve_endpoints so a federated authority watches the same
      # management server it would have resolved against.
      #
      # @return [Watch]
      def watch_endpoints(listener_name, authority: nil, &block)
        chain = chain_for(listener_name, authority)
        Watch.new(chain, chain.watch(&block))
      end

      def close
        connections = @mu.synchronize do
          @authorities.clear
          @listener_chains.clear
          conns = @connections.values
          @connections.clear
          @connection_refs.clear
          conns
        end
        connections.each(&:close)
        nil
      end

      # @api private -- ListenerChain's only way to talk to this client.
      # Subscribes +watcher_id+'s +block+ to (+type_url+, +name+) --
      # routed by #resource_authority(name), not by anything the caller
      # supplies -- and returns the entry's current [value, connection]
      # snapshot so a chain joining an already-resolved link (or a watcher
      # joining an already-resolved chain) can act on it once this
      # returns, without this client's own lock held.
      def subscribe_for(type_url, name, watcher_id, &block)
        @mu.synchronize { subscribe_locked(type_url, name, watcher_id, &block) }
      end

      private

      # A brand-new ListenerChain's constructor immediately calls back
      # into #subscribe_for (which takes @mu itself), so it must never be
      # built while @mu is held -- Ruby's Mutex is not reentrant. Two
      # threads racing to resolve the same never-before-seen name may each
      # build one; only the one that wins the race below is kept; the
      # other is discarded (its subscriptions are harmless no-ops next to
      # the winner's identical ones).
      def chain_for(listener_name, authority)
        resolved = resolved_listener_name(listener_name, authority)
        existing = @mu.synchronize { @listener_chains[resolved] }
        return existing unless existing.nil?
        chain = ListenerChain.new(self, resolved)
        @mu.synchronize { @listener_chains[resolved] ||= chain }
      end

      # Old-style (no authority) names go to the top-level xds_servers,
      # substituted through client_default_listener_resource_name_template
      # exactly as before federation existed. An authority-qualified name
      # is refused unless the bootstrap's "authorities" map defines it --
      # deliberately checked here too (Transport.parse_target already does,
      # for a target built through the public API) so a direct caller
      # cannot construct a channel to an unknown authority either.
      def resolved_listener_name(name, authority)
        return default_resolved_listener_name(name) if authority.nil?
        entry = @config.authorities[authority]
        if entry.nil?
          fail Error,
               "xds authority #{authority.inspect} is not defined by the xDS bootstrap's " \
               '"authorities" map'
        end
        entry.listener_resource_name_template.sub('%s', percent_encode(name))
      end

      def default_resolved_listener_name(name)
        return name if @listener_template.nil? || @listener_template.empty?
        @listener_template.sub('%s', name)
      end

      # The %s a client_listener_resource_name_template substitutes is a
      # URI path segment (gRFC A47): unreserved and sub-delim characters
      # pass through as-is, everything else (chiefly '/', which a plain
      # resource name may itself contain) is percent-encoded so the
      # resulting xdstp:// URI parses as the single path segment it names.
      def percent_encode(name)
        name.gsub(/[^A-Za-z0-9\-._~]/) { |c| c.each_byte.map { |b| format('%%%02X', b) }.join }
      end

      # gRFC A47: the authority a resource name routes to is the name's
      # own -- an "xdstp://<authority>/..." URI names +authority+
      # (normalized to the same +nil+ key as "old style" when it is the
      # empty default-authority form, "xdstp:///..."); anything else is
      # "old style" and always routes to the top-level xds_servers,
      # whichever authority's Listener happened to name it.
      XDSTP_AUTHORITY_RE = %r{\Axdstp://([^/]*)/}
      def resource_authority(name)
        m = XDSTP_AUTHORITY_RE.match(name)
        return nil if m.nil?
        m[1].empty? ? nil : m[1]
      end

      # +nil+ (an authority whose name does not appear in the bootstrap's
      # "authorities" map at all -- only reachable from a resource name
      # discovered mid-chain, since #resolved_listener_name already
      # refused an unknown *target* authority) rather than raising: gRFC
      # A71/A47 make this an error for that one resource, not the whole
      # client, so #subscribe_locked just leaves it forever unresolved
      # instead of tearing down whatever thread discovered it.
      def authority_servers_for(authority_key)
        return @config.servers if authority_key.nil?
        entry = @config.authorities[authority_key]
        return nil if entry.nil?
        entry.servers.nil? || entry.servers.empty? ? @config.servers : entry.servers
      end

      def subscribe_locked(type_url, name, watcher_id, &block)
        authority_key = resource_authority(name)
        astate = @authorities[authority_key]
        if astate.nil?
          servers = authority_servers_for(authority_key)
          if servers.nil?
            GRPC.logger.debug(
              "xDS: #{name.inspect} names authority #{authority_key.inspect}, which the bootstrap " \
              'does not define; it will never resolve'
            )
            return [nil, nil]
          end
          astate = @authorities[authority_key] = AuthorityState.new(servers)
        end
        entry = astate.resources[type_url][name] ||= ResourceEntry.new
        created = entry.watchers.empty?
        entry.watchers[watcher_id] = block
        ensure_channels_locked(astate) if created
        astate.channels.each { |conn| conn.subscribe(type_url, name) }
        [entry.value, entry.connection]
      end

      # ---- gRFC A71 fallback: adding servers, and falling back forward.

      # Adds servers from +astate.xds_servers+, starting where
      # +astate.channels+ leaves off, until one comes up presumed-healthy
      # (or the list runs out). Every resource this authority currently has
      # watchers for is (re)subscribed on each newly added connection, so
      # a fresh fallback server hears about everything already in play, not
      # just what triggered adding it.
      def maybe_add_channels_locked(astate)
        i = astate.channels.size
        while i < astate.xds_servers.size
          conn = connection_for(astate.xds_servers[i])
          astate.channels << conn
          retain_connection_locked(conn)
          resubscribe_all_locked(astate, conn)
          return true if conn.status_ok?
          i += 1
        end
        false
      end

      # Called when a brand-new resource is subscribed to: an authority
      # with no channels yet needs its first one, and one whose active
      # channel is already failing needs the next fallback server tried
      # too, since this newly-uncached resource may be exactly what would
      # have triggered #maybe_fallback_locked had the channel failed after
      # it existed instead of before.
      def ensure_channels_locked(astate)
        maybe_add_channels_locked(astate) if astate.channels.empty? || !astate.channels.last.status_ok?
      end

      # Called when the active (last) channel for an authority goes
      # unhealthy. Does nothing if every resource this authority watches is
      # already cached -- serving stale-but-known-good data beats an
      # unnecessary connection to a fallback server nobody asked for.
      def maybe_fallback_locked(astate)
        return false unless uncached_resources_locked?(astate)
        maybe_add_channels_locked(astate)
      end

      def uncached_resources_locked?(astate)
        astate.resources.each_value do |names|
          names.each_value { |entry| return true if !entry.watchers.empty? && entry.value.nil? }
        end
        false
      end

      def resubscribe_all_locked(astate, conn)
        astate.resources.each do |type_url, names|
          names.each { |name, entry| conn.subscribe(type_url, name) unless entry.watchers.empty? }
        end
      end

      # gRFC A71 "fall forward": +conn+ just proved itself alive (any ADS
      # response, not only ones naming resources that changed). For every
      # authority whose channel list contains +conn+ anywhere but the end,
      # promote it to active by dropping everything listed after it --
      # releasing (and, once nothing else needs them, closing) those
      # connections outside this client's own lock, since #close joins
      # threads and must never do that while @mu is held.
      def handle_channel_healthy(conn)
        to_close = []
        @mu.synchronize do
          @authorities.each_value do |astate|
            channels = astate.channels
            next if channels.empty? || channels.last.equal?(conn)
            idx = channels.index { |c| c.equal?(conn) }
            next if idx.nil?
            dropped = channels[(idx + 1)..]
            astate.channels = channels[0..idx]
            dropped.each { |d| to_close << d if release_connection_locked(d) }
          end
        end
        to_close.each(&:close)
      end

      # A connection's Channel went unhealthy. Only matters for an
      # authority actually using it as the active (last) one right now --
      # one still in the list but already fallen behind a healthier
      # channel has nothing left to trigger.
      def handle_channel_status_change(conn, healthy)
        return if healthy
        @mu.synchronize do
          @authorities.each_value do |astate|
            next if astate.channels.empty? || !astate.channels.last.equal?(conn)
            maybe_fallback_locked(astate)
          end
        end
      end

      # A response accepted resources for +type_url+ named +decoded+
      # (name => decoded message). Applied only to authorities/resources
      # that actually still have a subscription for that exact name --
      # gRFC A47 routes every name to exactly one authority
      # (#resource_authority), so this never has to guess which one, and a
      # server answering with something nobody asked for is silently
      # ignored.
      def handle_resource_response(conn, type_url, decoded)
        notify = []
        @mu.synchronize do
          decoded.each { |name, msg| apply_resource_locked(type_url, name, msg, conn, notify) }
        end
        notify.each { |block, msg, connection| block.call(msg, connection) }
      end

      def apply_resource_locked(type_url, name, msg, conn, notify)
        astate = @authorities[resource_authority(name)]
        return if astate.nil?
        entry = astate.resources[type_url][name]
        return if entry.nil?
        entry.value = msg
        entry.connection = conn
        entry.watchers.each_value { |block| notify << [block, msg, conn] }
      end

      # ---- The global connection pool: one AdsConnection per distinct
      # management server, shared across every authority that names it
      # (the same physical server named by two different authorities, or
      # by an authority and the top-level xds_servers, shares its ADS/LRS
      # connection rather than opening a second one), reference-counted by
      # how many authorities currently list it in AuthorityState#channels
      # so a server dropped by one fallback revert but still used by
      # another authority stays open.

      def connection_for(server)
        key = [server.server_uri, server.channel_creds_type]
        @connections[key] ||= AdsConnection.new(
          server, @node,
          on_resource: method(:handle_resource_response),
          on_healthy: method(:handle_channel_healthy),
          on_status_change: method(:handle_channel_status_change)
        )
      end

      def retain_connection_locked(conn)
        @connection_refs[conn] += 1
      end

      # @return [Boolean] whether +conn+'s refcount just hit zero and it
      #   should be closed (by the caller, outside @mu).
      def release_connection_locked(conn)
        remaining = @connection_refs[conn] - 1
        if remaining <= 0
          @connection_refs.delete(conn)
          @connections.delete(conn.dedup_key)
          return true
        end
        @connection_refs[conn] = remaining
        false
      end

      def build_node(node_hash)
        Envoy::Config::Core::V3::Node.new(
          id: node_hash['id'].to_s,
          cluster: node_hash['cluster'].to_s,
          metadata: json_to_struct(node_hash['metadata'] || {})
        )
      end

      def json_to_struct(hash)
        s = Google::Protobuf::Struct.new
        hash.each { |k, v| s.fields[k.to_s] = json_to_value(v) }
        s
      end

      def json_to_value(value)
        case value
        when nil then Google::Protobuf::Value.new(null_value: :NULL_VALUE)
        when true, false then Google::Protobuf::Value.new(bool_value: value)
        when Numeric then Google::Protobuf::Value.new(number_value: value.to_f)
        when Hash then Google::Protobuf::Value.new(struct_value: json_to_struct(value))
        when Array
          list = Google::Protobuf::ListValue.new(values: value.map { |e| json_to_value(e) })
          Google::Protobuf::Value.new(list_value: list)
        else Google::Protobuf::Value.new(string_value: value.to_s)
        end
      end
    end
  end
end

require_relative 'xds_lrs'
require_relative 'xds_listener_chain'
require_relative 'xds_ads_connection'
