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

require 'spec_helper'
require 'json'
require 'resolv'

# grpc.dns_enable_srv_queries and grpc.service_config_disable_resolution were
# both accepted and never acted on. A target behind a "_grpc_config._tcp"
# SRV record -- gRPC's DNS load-balancing convention -- resolved straight
# past it to the target's own A/AAAA records instead, and a channel had no
# way to stop the resolver's DNS TXT lookup from silently overriding the
# grpc.service_config it was given.
SrvResource = Resolv::DNS::Resource::IN::SRV
TxtResource = Resolv::DNS::Resource::IN::TXT

describe 'DNS SRV records and TXT-published service config' do
  def srv(priority:, weight:, port:, target:)
    instance_double(SrvResource, priority: priority, weight: weight, port: port, target: target)
  end

  def txt(data)
    instance_double(TxtResource, data: data)
  end

  # Stubs Resolv::DNS.open to answer +srv+ for the "_grpc_config._tcp.<host>"
  # SRV query and +txt+ for a plain TXT query on <host>, standing in for
  # what a real DNS server would return -- never touching the network.
  def stub_dns(srv: [], txt: [])
    dns = instance_double(Resolv::DNS)
    allow(dns).to receive(:getresources) do |name, typeclass|
      if typeclass == SrvResource
        name.start_with?('_grpc_config._tcp.') ? srv : []
      elsif typeclass == TxtResource
        txt
      else
        []
      end
    end
    allow(Resolv::DNS).to receive(:open) { |&block| block.call(dns) }
  end

  def stub_addrinfo(answers)
    allow(Addrinfo).to receive(:getaddrinfo) do |host, _port, *|
      (answers[host] || []).map { |ip| instance_double(Addrinfo, ip_address: ip) }
    end
  end

  describe GRPC::Core::Transport do
    describe '.resolve_addresses with grpc.dns_enable_srv_queries' do
      it 'ignores SRV records, and never queries them, when the argument is unset' do
        stub_dns(srv: [srv(priority: 0, weight: 0, port: 9000, target: 'backend1.internal')])
        stub_addrinfo('plain.example' => ['10.0.0.9'])
        expect(Resolv::DNS).not_to receive(:open)

        target = described_class.parse_target('plain.example:443')
        described_class.resolve_addresses(target, {})

        expect(target.addresses.map { |a| [a.host, a.port] }).to eq([['10.0.0.9', 443]])
      end

      it 'uses SRV targets and ports in place of the plain A/AAAA lookup when set' do
        stub_dns(srv: [srv(priority: 0, weight: 0, port: 9000, target: 'backend1.internal')])
        stub_addrinfo('backend1.internal' => ['10.0.0.1'], 'grpclb.example' => ['10.0.0.9'])

        target = described_class.parse_target('grpclb.example:443')
        args = { 'grpc.dns_enable_srv_queries' => 1 }
        described_class.resolve_addresses(target, args)

        expect(target.addresses.map { |a| [a.host, a.port] }).to eq([['10.0.0.1', 9000]])
      end

      it 'orders addresses by ascending SRV priority, then descending weight' do
        stub_dns(srv: [
                   srv(priority: 10, weight: 5, port: 1, target: 'low-priority.internal'),
                   srv(priority: 0, weight: 5, port: 2, target: 'heavy.internal'),
                   srv(priority: 0, weight: 20, port: 3, target: 'heavier.internal')
                 ])
        stub_addrinfo(
          'low-priority.internal' => ['10.0.0.3'],
          'heavy.internal' => ['10.0.0.2'],
          'heavier.internal' => ['10.0.0.1']
        )

        target = described_class.parse_target('grpclb.example:443')
        described_class.resolve_addresses(target, { 'grpc.dns_enable_srv_queries' => 1 })

        # heavier.internal (priority 0, weight 20) before heavy.internal
        # (priority 0, weight 5) before low-priority.internal (priority 10).
        expect(target.addresses.map(&:host)).to eq(%w[10.0.0.1 10.0.0.2 10.0.0.3])
      end

      it 'falls back to a plain A/AAAA lookup on the original host when there is no SRV record' do
        stub_dns(srv: [])
        stub_addrinfo('no-srv.example' => ['10.0.0.5', '10.0.0.6'])

        target = described_class.parse_target('no-srv.example:443')
        described_class.resolve_addresses(target, { 'grpc.dns_enable_srv_queries' => 1 })

        expect(target.addresses.map { |a| [a.host, a.port] })
          .to eq([['10.0.0.5', 443], ['10.0.0.6', 443]])
      end
    end

    describe '.service_config_json' do
      it 'strips the "grpc_config=" prefix from the TXT record and returns the JSON' do
        stub_dns(txt: [txt('grpc_config={"methodConfig":[]}')])
        target = described_class.parse_target('cfg.example:443')
        expect(described_class.service_config_json(target)).to eq('{"methodConfig":[]}')
      end

      it 'returns nil when no TXT record starts with "grpc_config="' do
        stub_dns(txt: [txt('unrelated=1')])
        target = described_class.parse_target('cfg.example:443')
        expect(described_class.service_config_json(target)).to be_nil
      end

      it 'never queries a :unix target' do
        expect(Resolv::DNS).not_to receive(:open)
        target = described_class.parse_target('unix:/tmp/some.sock')
        expect(described_class.service_config_json(target)).to be_nil
      end
    end
  end

  describe 'a Channel built from a DNS-published service config' do
    def build_channel(args)
      GRPC::Core::Channel.new('svc.example:443', args, :this_channel_is_insecure)
    end

    def service_config_json(timeout)
      JSON.generate(
        'methodConfig' => [
          { 'name' => [{ 'service' => 'pkg.Svc' }], 'timeout' => timeout }
        ]
      )
    end

    after(:each) { @ch&.destroy }

    it 'becomes the effective service config when the resolver publishes one' do
      allow(GRPC::Core::Transport).to receive(:service_config_json).and_return(service_config_json('7s'))

      @ch = build_channel(nil)

      expect(@ch.method_config('/pkg.Svc/Method').timeout).to eq(7.0)
    end

    it 'is not queried, and does not apply, once resolved: the grpc.service_config argument wins' do
      expect(GRPC::Core::Transport).not_to receive(:service_config_json)

      @ch = build_channel('grpc.service_config' => service_config_json('3s'))

      expect(@ch.method_config('/pkg.Svc/Method').timeout).to eq(3.0)
    end

    it 'is never looked up once grpc.service_config_disable_resolution is set' do
      expect(GRPC::Core::Transport).not_to receive(:service_config_json)

      @ch = build_channel('grpc.service_config_disable_resolution' => 1)

      expect(@ch.method_config('/pkg.Svc/Method')).to be_nil
    end
  end
end
