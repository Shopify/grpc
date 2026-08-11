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

require_relative 'health_watcher'

module GRPC
  module Core
    # The connection lifecycle for one resolved address. A Channel with N
    # resolved addresses holds N of these so an LB policy can track and pick
    # among them without reimplementing the dial/backoff bookkeeping that
    # used to live directly on Channel for its single connection.
    #
    # A subchannel that fails to connect stays in TRANSIENT_FAILURE for
    # good: retrying a specific dead address on its own backoff timer would
    # be a second backoff scheme, which is not wanted. Recovery instead
    # happens when the owning Channel re-resolves and rebuilds every
    # subchannel from scratch (see Channel#schedule_reresolve_locked).
    #
    # @api private
    class Subchannel
      attr_reader :address

      # Set once, by OutlierDetectionPolicy, before this subchannel is
      # handed to any LB policy; nil when outlier detection is not
      # configured. Subchannel only stores and forwards it (to the
      # Connection it dials, in #connect_worker) -- the counting itself
      # happens on Call's hot path, and the evaluation lives entirely in
      # OutlierDetectionPolicy#evaluate.
      attr_accessor :outlier_counter

      # +dial+ is called as dial.(address, on_close) => Connection, in a
      # background thread. +on_state_change+ is called with +self+, outside
      # this subchannel's lock, after every state transition, so the owner
      # can fold it into an aggregate connectivity state without risking a
      # lock-order inversion with the owner's own lock.
      #
      # +health_check_service_name+, when not nil, starts one HealthWatcher
      # per dialed connection (see #connect_worker): a client-side health
      # check per gRFC A17 that #alive? and #healthy? track alongside the
      # transport itself. +health_backoff_factory+ is called with no
      # arguments for a fresh ReconnectBackoff every time a watcher is
      # started, since a watch stream's own retry sequence must not share
      # state with another connection's, or with this subchannel's next one.
      def initialize(address, dial:, on_state_change: nil,
                     health_check_service_name: nil, health_backoff_factory: nil)
        @address = address
        @dial = dial
        @on_state_change = on_state_change
        @health_check_service_name = health_check_service_name
        @health_backoff_factory = health_backoff_factory
        @mu = Mutex.new
        @state = ConnectivityStates::IDLE
        @connection = nil
        @connect_thread = nil
        @last_error = nil
        @destroyed = false
        # No health check configured, or one configured but not yet told
        # otherwise, both mean eligible: gRFC A17 requires "healthy" to be
        # the default so a server without the health service still works.
        @healthy = true
        @health_watcher = nil
        # Sticky until the next evaluation interval un-ejects it (see
        # OutlierDetectionPolicy#evaluate) -- unlike @healthy, nothing but
        # that timer ever flips this back, so a transport that stays
        # perfectly healthy while ejected does not shake it loose early.
        @ejected = false
      end

      def state
        @mu.synchronize { @state }
      end

      def connection
        @mu.synchronize { @connection }
      end

      def healthy?
        @mu.synchronize { @healthy }
      end

      # A subchannel whose transport is up but whose health watcher has
      # reported anything other than SERVING must not be picked, even
      # though the transport itself would happily carry a call.
      def alive?
        @mu.synchronize { !@ejected && @healthy && !!@connection&.alive? }
      end

      # Called only by OutlierDetectionPolicy, from its timer thread. Ejection
      # does not touch @state or the real connection: the transport may be
      # fine, and un-ejecting it later must not pay to reconnect.
      def eject
        @ejected = true
      end

      def uneject
        @ejected = false
      end

      def last_error
        @mu.synchronize { @last_error }
      end

      # A no-op unless this address is IDLE, so an LB policy can poke every
      # subchannel on every tick without triggering duplicate dials. Does
      # not notify the owner: the caller already knows it just started a
      # dial (it is the one calling this) and folds CONNECTING into its own
      # aggregate itself, without a lock held here that could re-enter the
      # owner's Channel#maybe_start_connect and deadlock on its own mutex.
      def maybe_connect
        @mu.synchronize do
          next if @destroyed || @state != ConnectivityStates::IDLE
          @connect_thread = Thread.new { connect_worker }
          @connect_thread.name = 'grpc-connect'
          transition_locked(ConnectivityStates::CONNECTING)
        end
        nil
      end

      def close
        connection = nil
        watcher = nil
        changed = @mu.synchronize do
          next false if @destroyed
          @destroyed = true
          connection = @connection
          @connection = nil
          watcher = @health_watcher
          @health_watcher = nil
          transition_locked(ConnectivityStates::FATAL_FAILURE)
        end
        watcher&.stop
        connection&.close
        notify if changed
        nil
      end

      # Drops the inherited connection across a fork, exactly as
      # Channel#reset_after_fork! used to do for its single connection. The
      # mutex is replaced rather than taken, because a lock held at fork
      # time belongs to a thread that no longer exists.
      def abandon
        @connection&.abandon
        @mu = Mutex.new
        @connection = nil
        @connect_thread = nil
        @last_error = nil
        @healthy = true
        @health_watcher = nil
        @state = ConnectivityStates::IDLE unless @destroyed
        nil
      end

      private

      def connect_worker
        connection = @dial.call(@address, method(:on_connection_closed))
        changed = @mu.synchronize do
          @connect_thread = nil
          if @destroyed
            connection.close
            false
          else
            @connection = connection
            connection.outlier_counter = @outlier_counter if @outlier_counter
            @last_error = nil
            @healthy = true
            @health_watcher = start_health_watcher_locked(connection)
            transition_locked(ConnectivityStates::READY)
          end
        end
        notify if changed
      rescue StandardError => e
        changed = @mu.synchronize do
          @connect_thread = nil
          @last_error = e
          transition_locked(ConnectivityStates::TRANSIENT_FAILURE)
        end
        notify if changed
      end

      # Called with @mu held, from #connect_worker only: a HealthWatcher's
      # own thread may call back into #on_health_changed from a different
      # thread than the one holding this lock, which merely blocks it until
      # this synchronize block returns rather than deadlocking.
      def start_health_watcher_locked(connection)
        return nil if @health_check_service_name.nil?
        HealthWatcher.new(connection, @health_check_service_name,
                          @health_backoff_factory.call,
                          on_change: method(:on_health_changed))
      end

      # A health status flip does not change @state -- the transport is
      # exactly as connected as it was -- but it does change #alive?, so the
      # owner must recompute its aggregate the same way it does for a real
      # transition.
      def on_health_changed(healthy)
        changed = @mu.synchronize do
          next false if @healthy == healthy
          @healthy = healthy
          true
        end
        notify if changed
      end

      def on_connection_closed(connection)
        watcher = nil
        changed = @mu.synchronize do
          next false unless @connection.equal?(connection)
          watcher = @health_watcher
          @health_watcher = nil
          @connection = nil
          @healthy = true
          @destroyed ? false : transition_locked(ConnectivityStates::IDLE)
        end
        watcher&.stop
        notify if changed
      end

      def transition_locked(state)
        return false if @state == state
        @state = state
        true
      end

      def notify
        @on_state_change&.call(self)
      end
    end
  end
end
