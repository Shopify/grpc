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

require_relative 'rpc_stream'
require_relative 'status_codes'

module GRPC
  module Core
    # Client-side health checking per gRFC A17: one streaming Watch call
    # against grpc.health.v1.Health, driven directly off a Subchannel's own
    # connection rather than a second dialed transport. #on_change reports
    # every SERVING/not-SERVING flip so the owning Subchannel can fold it
    # into #alive?, exactly the way it already folds a transport failure in.
    #
    # A new instance is created for every connection a Subchannel dials --
    # never reused across a reconnect -- so a stale watcher can never update
    # a Subchannel about a connection it no longer holds.
    #
    # @api private
    class HealthWatcher
      SERVICE = 'grpc.health.v1.Health'

      # The generated message classes live under src/ruby/pb, alongside
      # every other .proto this repo generates, not under lib/ where
      # $LOAD_PATH already reaches (see XdsClient::load_xds! for the same
      # trick). Loaded here, on first use, so a channel with no
      # healthCheckConfig never pays for the protobuf descriptors.
      PB_DIR = File.expand_path('../../../pb', __dir__)

      # Watch is meant to sit open indefinitely between status changes; this
      # only bounds how long a read may block so a half-dead peer that
      # stopped sending anything -- no message, no GOAWAY, no RST_STREAM --
      # still gets retried instead of parking this thread forever.
      RESPONSE_TIMEOUT = 3600.0

      # +backoff+ is this watcher's own ReconnectBackoff, not the one the
      # owning Channel advances for reconnecting the transport itself:
      # a health stream can drop and be retried many times while the
      # transport underneath it stays perfectly healthy, and folding the
      # two sequences together would make an unrelated failure retry faster
      # or slower than its own backoff promises.
      def initialize(connection, service_name, backoff, on_change:)
        $LOAD_PATH.unshift(PB_DIR) unless $LOAD_PATH.include?(PB_DIR)
        require 'grpc/health/v1/health_pb'
        @connection = connection
        @service_name = service_name
        @backoff = backoff
        @on_change = on_change
        @mu = Mutex.new
        @stopped = false
        @stream = nil
        @thread = Thread.new { run }
        @thread.name = 'grpc-health'
      end

      # Unblocks a thread parked in a read or in the retry backoff, then
      # waits for it to notice and exit.
      def stop
        stream = @mu.synchronize do
          @stopped = true
          @stream
        end
        stream&.push_failure(StatusCodes::CANCELLED, 'health watch stopped')
        # #run may be asleep in the backoff between attempts rather than
        # blocked in a read; Thread#wakeup ends that sleep early exactly as
        # Connection#stop_maintenance already does for its own timer thread.
        @thread.wakeup if @thread.alive?
        @thread.join
        nil
      end

      private

      def stopped?
        @mu.synchronize { @stopped }
      end

      def run
        until stopped?
          watch_once
          break if stopped?
          sleep(@backoff.next_delay)
        end
      end

      # Runs one Watch stream from HEADERS to however it ends. +stream+ is
      # always handed back to the connection's own bookkeeping afterwards
      # (see Connection#forget) -- exactly what Call does for a normal RPC
      # -- because nothing else would: a connection with a stream nobody
      # ever forgets never looks idle to grpc.client_idle_timeout and never
      # finishes draining after a GOAWAY (see Connection#on_goaway).
      def watch_once
        stream = @connection.open_rpc
        @mu.synchronize { @stream = stream }
        send_request(stream)
        read_responses(stream)
      rescue StandardError
        # Opening the stream, or writing the request, failed outright --
        # the transport-failure half of gRFC A17's fallback (see
        # #read_responses for the other half: a stream that opened but
        # never answered).
        @on_change.call(true)
      ensure
        @mu.synchronize { @stream = nil }
        forget(stream)
      end

      def forget(stream)
        return if stream.nil?
        stream.reset(8) unless stream.remote_closed? # HTTP/2 CANCEL
        stream.connection.forget(stream.id)
      end

      def send_request(stream)
        stream.send_headers(request_headers)
        request = Grpc::Health::V1::HealthCheckRequest.new(service: @service_name)
        stream.send_message(Grpc::Health::V1::HealthCheckRequest.encode(request))
        stream.close_send
      end

      def request_headers
        [
          [':method', 'POST'],
          [':scheme', 'http'],
          [':path', "/#{SERVICE}/Watch"],
          [':authority', @connection.peer],
          ['content-type', 'application/grpc'],
          ['te', 'trailers']
        ]
      end

      # Reports every SERVING/not-SERVING flip as it arrives. A stream that
      # fails outright -- +stream.failure+ set, e.g. the connection died or
      # this watcher was #stop-ped -- always falls back to healthy, per
      # gRFC A17's "healthy meanwhile" for whatever this side could not
      # finish talking to. A stream that instead ends *gracefully* keeps
      # the last reported status once at least one response has arrived:
      # a real answer already came back, and a clean close says nothing
      # that contradicts it. Only a graceful end with no response at all
      # (a server without the health service, or one that has not decided
      # yet) falls back to healthy too.
      def read_responses(stream)
        received_any = false
        loop do
          payload = stream.read_message(RpcStream.now + RESPONSE_TIMEOUT)
          if payload.nil?
            failed = !stream.failure.nil?
            @on_change.call(true) if failed || !received_any
            stop_if_unimplemented(stream) unless failed
            return
          end
          @backoff.reset unless received_any
          received_any = true
          status = Grpc::Health::V1::HealthCheckResponse.decode(payload).status
          @on_change.call(status == :SERVING)
        end
      end

      # The proto's own doc comment on Watch: a call that terminates with
      # UNIMPLEMENTED means the peer carries no health service at all and
      # should not be retried, unlike any other ending (including a clean
      # OK), which gets the usual backoff-and-reconnect treatment.
      def stop_if_unimplemented(stream)
        code = stream.await_trailers(RpcStream.now).find { |name, _| name == 'grpc-status' }&.last
        @mu.synchronize { @stopped = true } if code&.to_i == StatusCodes::UNIMPLEMENTED
      end
    end
  end
end
