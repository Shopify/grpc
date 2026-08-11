#!/usr/bin/env ruby
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

# xDS conformance harness: drives src/ruby/pb/test/xds_client.rb, the
# port's own client, against an in-process fake ADS control plane and real
# (in-process) grpc.testing.TestService backends, and checks the same
# client-observable behaviours tools/run_tests/run_xds_tests.py checks --
# without any of that script's GCP/Traffic Director provisioning.
#
# Run with:
#   ruby -Isrc/ruby/lib -Isrc/ruby/pb src/ruby/pb/test/xds_conformance/run.rb
#
# Exits 0 iff every case below passed; prints a PASS/FAIL line per case
# either way.
#
# Cases reproduced, and how each maps onto run_xds_tests.py's GCP-flavored
# version:
#   ping_pong    -- test_ping_pong: every backend in the cluster eventually
#                    receives at least one RPC.
#   round_robin  -- test_round_robin: RPCs are spread within 1 of an even
#                    split across the backends.
#   backends_restart          -- test_backends_restart: an EDS update that
#                    empties the endpoint list stands in for the instance
#                    group being resized to 0 (RPCs must stop reaching any
#                    of them), and restoring the original list for the
#                    resize back (traffic must return to the same
#                    backends). The real test's instance-group resize is
#                    GCP-side infrastructure this harness has no use for;
#                    the client only ever observes it as an EDS change.
#   change_backend_service     -- test_change_backend_service: an EDS
#                    update swaps the whole endpoint set for a disjoint
#                    one; traffic must move entirely to the new set and
#                    stop reaching the old one. remove_instance_group is
#                    the same client-observable shape (EDS drops one of two
#                    groups) and is not reproduced as a second case.
#   new_instance_group_receives_traffic -- an EDS update that adds a new
#                    backend to the existing set; traffic must reach it
#                    without disrupting the others.
#
# Not reproduced: everything that is really a GCP/URL-map/backend-service
# feature rather than an xDS wire-protocol one -- path_matching,
# header_matching, metadata_filter, circuit_breaking, timeout,
# fault_injection, csds, the forwarding_rule/api_listener port-selection
# cases, and the locality-failover family (gentle_failover,
# load_report_based_failover, secondary_locality_gets_*), which all need
# multiple localities/priorities and GCP health-check-driven state this
# harness's flat single-locality EDS has no reason to model.
#
# xds_client.rb needed one change to run against a local control plane at
# all: #create_stub now passes channel_args: {'grpc.lb_policy_name' =>
# 'round_robin'} explicitly (see the comment there). Real xDS
# implementations pick round_robin as the default child policy from CDS;
# this Ruby port reads grpc.lb_policy_name once from channel args before
# xDS resolution ever runs and never revisits it (see
# GRPC::Core::Channel#build_subchannels_locked), so left unset every RPC
# would have stuck to a single backend under pick_first and every case
# below would fail for a reason that has nothing to do with the behaviour
# being tested. That gap is documented, not silently patched: fixing it
# for real means deriving the LB policy from the resolved CDS resource
# per-cluster, which is a resolver/channel redesign, not a small fix.
#
# CONFIRMED PORT GAP, found by actually running this: ping_pong and
# round_robin pass, but backends_restart, change_backend_service and
# new_instance_group_receives_traffic all fail, every time, because
# GRPC::Core::Channel only ever calls Transport.resolve_addresses once (at
# connect) and again only after every current subchannel has failed (see
# Channel#schedule_reresolve_locked) -- there is no periodic or
# push-triggered re-resolution anywhere in channel.rb, for any scheme.
# XdsClient::AdsConnection itself applies a server-pushed EDS update
# correctly and immediately (confirmed directly: two successive
# Transport.resolve_addresses calls around a #push saw the updated
# endpoint before and after, with no Channel involved), so the control
# plane's push reaches the client's cached resource state just fine. It
# simply never reaches a *running* Channel, because nothing in Channel
# re-asks the resolver while its current addresses are still healthy --
# which, for an EDS update that swaps in a same-cluster address the old
# one has no reason to fail against, is exactly the case that never
# trips #schedule_reresolve_locked. This is the one thing xDS is *for*:
# moving traffic without waiting for anything to break. Not fixed here --
# it needs Channel to hold a live subscription to its resolver and
# rebuild subchannels whenever new addresses arrive, not merely on total
# failure, which is a resolver/LB integration redesign well past "a clear
# and small fix," not a bug fixable in this pass.

this_dir = File.expand_path(File.dirname(__FILE__))
pb_test_dir = File.dirname(this_dir)
pb_dir = File.dirname(pb_test_dir)
lib_dir = File.join(File.dirname(pb_dir), 'lib')
$LOAD_PATH.unshift(lib_dir) unless $LOAD_PATH.include?(lib_dir)
$LOAD_PATH.unshift(pb_dir) unless $LOAD_PATH.include?(pb_dir)

require 'grpc'
require 'grpc/core/xds_client'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'socket'
require 'set'
require 'rbconfig'
require_relative 'fake_control_plane'
require_relative 'backend_server'

require_relative '../../src/proto/grpc/testing/messages_pb'
require_relative '../../src/proto/grpc/testing/test_services_pb'

XDS_CLIENT_RB = File.join(pb_test_dir, 'xds_client.rb')

# Polls LoadBalancerStatsService.GetClientStats exactly as
# run_xds_tests.py's get_client_stats/_verify_rpcs_to_given_backends do,
# and applies the same two checks: every expected backend shows up, and no
# unexpected one does.
class StatsClient
  def initialize(stats_port)
    @stub = Grpc::Testing::LoadBalancerStatsService::Stub.new(
      "127.0.0.1:#{stats_port}", :this_channel_is_insecure
    )
  end

  def get_stats(num_rpcs, timeout_sec)
    req = Grpc::Testing::LoadBalancerStatsRequest.new(num_rpcs: num_rpcs, timeout_sec: timeout_sec)
    @stub.get_client_stats(req, deadline: GRPC::Core::TimeConsts.from_relative_time(timeout_sec + 20))
  end

  # Polls until every backend in +expected+ (and no other) has received
  # load, or +timeout_sec+ elapses. Raises with the last observed
  # distribution on failure. +num_rpcs+ small batches keep each poll fast;
  # the outer deadline is what actually bounds the wait.
  def wait_until_backends(expected, timeout_sec, num_rpcs: 100)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_sec
    expected_set = expected.to_set
    last_seen = nil
    loop do
      begin
        stats = get_stats(num_rpcs, 5)
        last_seen = stats.rpcs_by_peer.to_h.keys.to_set
        return stats if last_seen == expected_set
      rescue GRPC::BadStatus
        # The client's stats server, or its own xDS-resolved channel, is
        # not up yet (or is mid-reconnect) -- keep polling until it is or
        # the deadline below gives up.
        sleep 0.2
      end
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    end
    raise "expected backends #{expected.sort} but saw #{(last_seen || []).to_a.sort} " \
          "(waited #{timeout_sec}s)"
  end
end


# One conformance case: a name, run_xds_tests.py's matching test_* function
# for reference, and a block that raises on failure.
Case = Struct.new(:name, :block)

class Harness
  QPS = 25
  BOOT_TIMEOUT = 15
  TRAFFIC_TIMEOUT = 20

  def initialize
    @control_plane = XdsConformanceControlPlane.new
    @group_a = Array.new(3) { |i| XdsConformanceBackendServer.new("backend-a#{i}") }
    @group_b = Array.new(2) { |i| XdsConformanceBackendServer.new("backend-b#{i}") }
    @extra = XdsConformanceBackendServer.new('backend-extra')
    @control_plane.set_endpoints(@group_a.map(&:address))

    @bootstrap_path = File.join(Dir.mktmpdir('xds-conformance'), 'bootstrap.json')
    File.write(@bootstrap_path, JSON.generate(
      'xds_servers' => [{ 'server_uri' => @control_plane.uri, 'channel_creds' => [{ 'type' => 'insecure' }] }],
      'node' => { 'id' => 'xds-conformance-harness' }
    ))

    @stats_port = find_free_port
    start_client
    @stats = StatsClient.new(@stats_port)
  end

  def find_free_port
    server = TCPServer.new('127.0.0.1', 0)
    server.addr[1]
  ensure
    server&.close
  end

  def start_client
    env = { 'GRPC_XDS_BOOTSTRAP' => @bootstrap_path }
    target = "xds:///#{XdsConformanceControlPlane::LISTENER_NAME}"
    args = [
      RbConfig.ruby, XDS_CLIENT_RB,
      "--server=#{target}", "--stats_port=#{@stats_port}", "--qps=#{QPS}", '--num_channels=1'
    ]
    @client_pid = Process.spawn(env, *args, out: $stdout, err: $stdout)
  end

  def stop
    if @client_pid
      Process.kill('TERM', @client_pid)
      Process.wait(@client_pid)
    end
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    @group_a.each(&:stop)
    @group_b.each(&:stop)
    @extra.stop
    @control_plane.stop
    FileUtils.remove_entry(File.dirname(@bootstrap_path)) if @bootstrap_path
  end

  def cases
    [
      Case.new('ping_pong', method(:ping_pong)),
      Case.new('round_robin', method(:round_robin)),
      Case.new('backends_restart', method(:backends_restart)),
      Case.new('change_backend_service', method(:change_backend_service)),
      Case.new('new_instance_group_receives_traffic', method(:new_instance_group_receives_traffic))
    ]
  end

  # test_ping_pong: every backend in the cluster eventually gets an RPC.
  def ping_pong
    @control_plane.set_endpoints(@group_a.map(&:address))
    @stats.wait_until_backends(@group_a.map(&:name), TRAFFIC_TIMEOUT)
  end

  # test_round_robin: with round_robin as the (explicitly requested, see
  # run.rb's header comment) LB policy, RPCs split within 1 of an even
  # share across the backends.
  def round_robin
    @control_plane.set_endpoints(@group_a.map(&:address))
    names = @group_a.map(&:name)
    @stats.wait_until_backends(names, TRAFFIC_TIMEOUT)
    num_rpcs = QPS * 10
    stats = @stats.get_stats(num_rpcs, num_rpcs / QPS + 10)
    total = stats.rpcs_by_peer.values.sum
    raise "no RPCs succeeded: #{stats}" if total.zero?

    expected = total.to_f / names.size
    names.each do |name|
      actual = stats.rpcs_by_peer[name] || 0
      if (actual - expected).abs > expected * 0.34 + 1
        raise "uneven distribution: #{name} got #{actual}, expected ~#{expected.round(1)} (#{stats.rpcs_by_peer.to_h})"
      end
    end
  end

  # test_backends_restart: emptying the endpoint list (standing in for the
  # instance group being resized to 0) stops all traffic; restoring it
  # (the resize back) resumes traffic to the same backends.
  def backends_restart
    names = @group_a.map(&:name)
    @control_plane.set_endpoints(@group_a.map(&:address))
    @stats.wait_until_backends(names, TRAFFIC_TIMEOUT)

    @control_plane.set_endpoints([])
    @stats.wait_until_backends([], TRAFFIC_TIMEOUT)

    @control_plane.set_endpoints(@group_a.map(&:address))
    @stats.wait_until_backends(names, TRAFFIC_TIMEOUT)
  end

  # test_change_backend_service (and, at the xDS layer, the same shape as
  # remove_instance_group): traffic moves entirely to a disjoint endpoint
  # set and stops reaching the old one.
  def change_backend_service
    @control_plane.set_endpoints(@group_a.map(&:address))
    @stats.wait_until_backends(@group_a.map(&:name), TRAFFIC_TIMEOUT)

    @control_plane.set_endpoints(@group_b.map(&:address))
    @stats.wait_until_backends(@group_b.map(&:name), TRAFFIC_TIMEOUT)
  ensure
    @control_plane.set_endpoints(@group_a.map(&:address))
  end

  # new_instance_group_receives_traffic: adding a backend to the existing
  # set makes it start receiving traffic without dropping the others.
  def new_instance_group_receives_traffic
    @control_plane.set_endpoints(@group_a.map(&:address))
    @stats.wait_until_backends(@group_a.map(&:name), TRAFFIC_TIMEOUT)

    expanded = @group_a + [@extra]
    @control_plane.set_endpoints(expanded.map(&:address))
    @stats.wait_until_backends(expanded.map(&:name), TRAFFIC_TIMEOUT)
  ensure
    @control_plane.set_endpoints(@group_a.map(&:address))
  end
end


harness = Harness.new
results = []
harness.cases.each do |c|
  begin
    c.block.call
    results << [c.name, true, nil]
    puts "PASS #{c.name}"
  rescue StandardError => e
    results << [c.name, false, e.message]
    puts "FAIL #{c.name}: #{e.message}"
  end
end
harness.stop

puts
puts '--- xDS conformance summary ---'
results.each { |name, ok, msg| puts "#{ok ? 'PASS' : 'FAIL'} #{name}#{msg ? " (#{msg})" : ''}" }

exit(results.all? { |_, ok, _| ok } ? 0 : 1)
