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

      # +dial+ is called as dial.(address, on_close) => Connection, in a
      # background thread. +on_state_change+ is called with +self+, outside
      # this subchannel's lock, after every state transition, so the owner
      # can fold it into an aggregate connectivity state without risking a
      # lock-order inversion with the owner's own lock.
      def initialize(address, dial:, on_state_change: nil)
        @address = address
        @dial = dial
        @on_state_change = on_state_change
        @mu = Mutex.new
        @state = ConnectivityStates::IDLE
        @connection = nil
        @connect_thread = nil
        @last_error = nil
        @destroyed = false
      end

      def state
        @mu.synchronize { @state }
      end

      def connection
        @mu.synchronize { @connection }
      end

      def alive?
        @mu.synchronize { !!@connection&.alive? }
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
        changed = @mu.synchronize do
          next false if @destroyed
          @destroyed = true
          connection = @connection
          @connection = nil
          transition_locked(ConnectivityStates::FATAL_FAILURE)
        end
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
            @last_error = nil
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

      def on_connection_closed(connection)
        changed = @mu.synchronize do
          next false unless @connection.equal?(connection)
          @connection = nil
          @destroyed ? false : transition_locked(ConnectivityStates::IDLE)
        end
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
