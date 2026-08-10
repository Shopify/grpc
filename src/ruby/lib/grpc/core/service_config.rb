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

require 'json'
require_relative 'status_codes'

module GRPC
  module Core
    # Parses the JSON service config carried by grpc.service_config
    # (https://github.com/grpc/grpc/blob/master/doc/service_config.md) and
    # answers "what applies to this RPC", honouring gRPC's own precedence:
    # an exact service+method entry beats a service-wide entry, which beats
    # the channel default.
    #
    # @api private
    class ServiceConfig
      # The settings that apply to one RPC. +wait_for_ready+ is parsed but
      # never consulted: this core has no notion of a subchannel being
      # transiently unready to wait on (create_call either has a transport
      # or it doesn't), so there is nothing for it to change.
      MethodConfig = Struct.new(:timeout, :retry_policy, :wait_for_ready)

      RetryPolicy = Struct.new(:max_attempts, :initial_backoff, :max_backoff,
                               :backoff_multiplier, :retryable_status_codes)

      # Maps the enum names service config JSON uses ("UNAVAILABLE", ...) to
      # the integers this core's status codes are compared as.
      STATUS_CODES_BY_NAME = StatusCodes.constants.each_with_object({}) do |name, acc|
        acc[name.to_s] = StatusCodes.const_get(name)
      end.freeze

      # @param json [String] a service config document
      # @raise [ArgumentError] naming grpc.service_config, on anything the
      #   document does not parse into: malformed JSON, a duration that
      #   isn't "<number>s", or a retryPolicy missing a required field.
      def initialize(json)
        @by_exact_method = {} # "pkg.Svc/Method" => MethodConfig
        @by_service = {}      # "pkg.Svc"        => MethodConfig
        @default = nil        # MethodConfig, from a {} name entry
        parse(parse_json(json))
      end

      # Returns the MethodConfig that applies to +path+ (e.g.
      # "/pkg.Svc/Method"), preferring an exact service+method match, then a
      # service-wide match, then the channel default. nil if none apply.
      def method_config(path)
        _prefix, service, method = path.to_s.split('/', 3)
        return @default if service.nil?
        @by_exact_method["#{service}/#{method}"] || @by_service[service] || @default
      end

      private

      def parse_json(json)
        JSON.parse(json)
      rescue JSON::ParserError => e
        raise ArgumentError, "grpc.service_config is not valid JSON: #{e.message}"
      end

      def parse(doc)
        unless doc.is_a?(Hash)
          raise ArgumentError, 'grpc.service_config must be a JSON object'
        end
        Array(doc['methodConfig']).each { |cfg| parse_method_config(cfg) }
      end

      def parse_method_config(cfg)
        unless cfg.is_a?(Hash)
          raise ArgumentError, 'grpc.service_config: methodConfig entries must be objects'
        end
        config = MethodConfig.new(parse_duration(cfg['timeout']),
                                  parse_retry_policy(cfg['retryPolicy']),
                                  cfg['waitForReady'])
        Array(cfg['name']).each { |name| index_name(name, config) }
      end

      # An empty name (no service) is the channel default; a name with a
      # service but no method matches every method of that service; a name
      # with both is exact. A later methodConfig with the same name wins,
      # since the JSON schema does not require names to be unique.
      def index_name(name, config)
        unless name.is_a?(Hash)
          raise ArgumentError, 'grpc.service_config: name entries must be objects'
        end
        service = name['service']
        method = name['method']
        if service.nil? || service.empty?
          @default = config
        elsif method.nil? || method.empty?
          @by_service[service] = config
        else
          @by_exact_method["#{service}/#{method}"] = config
        end
      end

      # google.protobuf.Duration's JSON mapping: a decimal number of seconds
      # followed by "s", e.g. "1.5s". Returns nil for an absent timeout.
      def parse_duration(str)
        return nil if str.nil?
        match = /\A(\d+(?:\.\d+)?)s\z/.match(str)
        unless match
          raise ArgumentError, "grpc.service_config has a malformed duration #{str.inspect}"
        end
        match[1].to_f
      end

      def parse_retry_policy(policy)
        return nil if policy.nil?
        unless policy.is_a?(Hash)
          raise ArgumentError, 'grpc.service_config: retryPolicy must be an object'
        end
        RetryPolicy.new(Integer(require_field(policy, 'maxAttempts')),
                        parse_duration(require_field(policy, 'initialBackoff')),
                        parse_duration(require_field(policy, 'maxBackoff')),
                        Float(require_field(policy, 'backoffMultiplier')),
                        retryable_codes(policy['retryableStatusCodes']))
      rescue TypeError, ArgumentError => e
        raise ArgumentError, "grpc.service_config has a malformed retryPolicy: #{e.message}"
      end

      def require_field(policy, field)
        value = policy[field]
        raise ArgumentError, "retryPolicy is missing #{field}" if value.nil?
        value
      end

      def retryable_codes(names)
        Array(names).map do |name|
          STATUS_CODES_BY_NAME.fetch(name) do
            raise ArgumentError, "retryableStatusCodes has an unknown code #{name.inspect}"
          end
        end
      end
    end
  end
end
