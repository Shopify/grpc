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

require 'json'

module GRPC
  module Core
    # Reads and validates the xDS bootstrap file gRPC's xDS implementations
    # agree on (see gRFC A27): where the management server lives, which
    # channel credentials to use to reach it, and the node identity to
    # present. An xds:// target is meaningless without one, so every error
    # here names the environment variable the caller needs to fix rather
    # than surfacing as a mysterious connect failure later.
    #
    # @api private
    module XdsBootstrap
      Error = Class.new(StandardError)

      # One entry from "xds_servers": where the management server is and
      # what channel credentials to dial it with. Only the first entry is
      # used -- falling back to a secondary management server on failure is
      # not implemented.
      XdsServer = Struct.new(:server_uri, :channel_creds_type)

      # One entry from the top-level "authorities" map (gRFC A47): the
      # servers a federated "xds://<name>/resource" target is resolved
      # against (nil when the entry has no "xds_servers" of its own, so the
      # top-level servers apply instead), and the template an
      # authority-qualified resource name is built from.
      Authority = Struct.new(:servers, :listener_resource_name_template)

      Config = Struct.new(:servers, :node, :listener_resource_name_template, :authorities)

      module_function

      # @return [Config]
      def load
        parse(read_source)
      end

      def read_source
        path = ENV['GRPC_XDS_BOOTSTRAP']
        return read_file(path) if path && !path.empty?
        inline = ENV['GRPC_XDS_BOOTSTRAP_CONFIG']
        return inline if inline && !inline.empty?
        fail Error,
             'an xds:// target requires GRPC_XDS_BOOTSTRAP (a path to a bootstrap file) or ' \
             'GRPC_XDS_BOOTSTRAP_CONFIG (inline bootstrap JSON) to be set'
      end

      def read_file(path)
        File.read(path)
      rescue SystemCallError => e
        fail Error, "cannot read the file named by GRPC_XDS_BOOTSTRAP (#{path.inspect}): #{e.message}"
      end

      def parse(json)
        data = JSON.parse(json)
        fail Error, 'the xDS bootstrap config must be a JSON object' unless data.is_a?(Hash)
        Config.new(parse_servers(data), data['node'] || {},
                   data['client_default_listener_resource_name_template'], parse_authorities(data))
      rescue JSON::ParserError => e
        fail Error, "the xDS bootstrap config is not valid JSON: #{e.message}"
      end

      def parse_servers(data)
        list = data['xds_servers']
        unless list.is_a?(Array) && !list.empty?
          fail Error, 'the xDS bootstrap config is missing a non-empty "xds_servers" array'
        end
        list.map { |entry| parse_server(entry) }
      end

      def parse_server(entry)
        fail Error, 'each "xds_servers" entry must be a JSON object' unless entry.is_a?(Hash)
        uri = entry['server_uri']
        fail Error, 'an "xds_servers" entry is missing "server_uri"' if uri.nil? || uri.empty?
        creds = Array(entry['channel_creds'])
        fail Error, "xds_servers entry #{uri.inspect} is missing \"channel_creds\"" if creds.empty?
        type = creds.first.is_a?(Hash) ? creds.first['type'] : nil
        fail Error, "xds_servers entry #{uri.inspect} has a channel_creds entry with no \"type\"" if type.nil?
        XdsServer.new(uri, type)
      end

      def parse_authorities(data)
        raw = data['authorities']
        return {} if raw.nil?
        fail Error, 'the xDS bootstrap config\'s "authorities" must be a JSON object' unless raw.is_a?(Hash)
        raw.to_h { |name, entry| [name, parse_authority(name, entry)] }
      end

      def parse_authority(name, entry)
        fail Error, "authorities entry #{name.inspect} must be a JSON object" unless entry.is_a?(Hash)
        servers = entry.key?('xds_servers') ? parse_servers(entry) : nil
        template = entry['client_listener_resource_name_template'] ||
                   "xdstp://#{name}/envoy.config.listener.v3.Listener/%s"
        unless template.start_with?("xdstp://#{name}/")
          fail Error,
               "authorities entry #{name.inspect} has a \"client_listener_resource_name_template\" " \
               "that does not start with \"xdstp://#{name}/\""
        end
        Authority.new(servers, template)
      end
    end
  end
end
