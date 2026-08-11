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
require_relative 'outlier_detection'
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
      MethodConfig = Struct.new(:timeout, :retry_policy, :hedging_policy, :wait_for_ready)

      RetryPolicy = Struct.new(:max_attempts, :initial_backoff, :max_backoff,
                               :backoff_multiplier, :retryable_status_codes)

      # A method config carries at most one of retry_policy/hedging_policy:
      # gRPC treats "both configured" as a malformed methodConfig, since
      # they are two different responses to the same failure (one after
      # the other vs. several in parallel) and combining them isn't defined.
      HedgingPolicy = Struct.new(:max_attempts, :hedging_delay, :non_fatal_status_codes)

      # gRFC A17 client-side health checking: +service_name+ is what
      # HealthWatcher asks grpc.health.v1.Health/Watch about on each
      # subchannel. Nil (no healthCheckConfig in the document) leaves
      # health checking off, same as grpc.inhibit_health_checking would.
      HealthCheckConfig = Struct.new(:service_name)

      # Maps the enum names service config JSON uses ("UNAVAILABLE", ...) to
      # the integers this core's status codes are compared as.
      STATUS_CODES_BY_NAME = StatusCodes.constants.each_with_object({}) do |name, acc|
        acc[name.to_s] = StatusCodes.const_get(name)
      end.freeze

      attr_reader :health_check_config, :outlier_detection

      # @param json [String] a service config document
      # @raise [ArgumentError] naming grpc.service_config, on anything the
      #   document does not parse into: malformed JSON, a duration that
      #   isn't "<number>s", or a retryPolicy missing a required field.
      def initialize(json)
        @by_exact_method = {} # "pkg.Svc/Method" => MethodConfig
        @by_service = {}      # "pkg.Svc"        => MethodConfig
        @default = nil        # MethodConfig, from a {} name entry
        @health_check_config = nil
        @outlier_detection = nil
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
        @health_check_config = parse_health_check_config(doc['healthCheckConfig'])
        @outlier_detection = parse_outlier_detection(doc['outlierDetection'])
      end

      def parse_health_check_config(cfg)
        return nil if cfg.nil?
        unless cfg.is_a?(Hash)
          raise ArgumentError, 'grpc.service_config: healthCheckConfig must be an object'
        end
        name = cfg['serviceName']
        return nil unless name.is_a?(String)
        HealthCheckConfig.new(name)
      end

      # childPolicy is not consulted here: Channel already chose the child
      # LB policy from grpc.lb_policy_name before OutlierDetectionPolicy
      # ever wraps it (see Channel#build_subchannels_locked), and this
      # implementation has no separate loadBalancingConfig selection
      # mechanism for outlierDetection's childPolicy field to feed.
      def parse_outlier_detection(cfg)
        return nil if cfg.nil?
        unless cfg.is_a?(Hash)
          raise ArgumentError, 'grpc.service_config: outlierDetection must be an object'
        end
        OutlierDetection::Config.new(
          interval: parse_duration(cfg['interval']) || 10.0,
          base_ejection_time: parse_duration(cfg['baseEjectionTime']) || 30.0,
          max_ejection_time: parse_duration(cfg['maxEjectionTime']) || 300.0,
          max_ejection_percent: cfg['maxEjectionPercent'] || 10,
          **parse_success_rate_ejection(cfg['successRateEjection']),
          **parse_failure_percentage_ejection(cfg['failurePercentageEjection'])
        )
      rescue TypeError, ArgumentError => e
        raise ArgumentError, "grpc.service_config has a malformed outlierDetection: #{e.message}"
      end

      # nil for every field disables the success-rate algorithm entirely
      # (see OutlierDetectionPolicy#evaluate) -- absence of the sub-message
      # is not the same as an empty one, which enables it with defaults.
      def parse_success_rate_ejection(cfg)
        if cfg.nil?
          return { success_rate_stdev_factor: nil, success_rate_enforcement_percentage: nil,
                   success_rate_minimum_hosts: nil, success_rate_request_volume: nil }
        end
        unless cfg.is_a?(Hash)
          raise ArgumentError, 'successRateEjection must be an object'
        end
        {
          success_rate_stdev_factor: cfg['stdevFactor'] || 1900,
          success_rate_enforcement_percentage: cfg['enforcementPercentage'] || 100,
          success_rate_minimum_hosts: cfg['minimumHosts'] || 5,
          success_rate_request_volume: cfg['requestVolume'] || 100
        }
      end

      # Same nil-disables-the-algorithm rule as #parse_success_rate_ejection.
      def parse_failure_percentage_ejection(cfg)
        if cfg.nil?
          return { failure_percentage_threshold: nil, failure_percentage_enforcement_percentage: nil,
                   failure_percentage_minimum_hosts: nil, failure_percentage_request_volume: nil }
        end
        unless cfg.is_a?(Hash)
          raise ArgumentError, 'failurePercentageEjection must be an object'
        end
        {
          failure_percentage_threshold: cfg['threshold'] || 85,
          failure_percentage_enforcement_percentage: cfg['enforcementPercentage'] || 100,
          failure_percentage_minimum_hosts: cfg['minimumHosts'] || 5,
          failure_percentage_request_volume: cfg['requestVolume'] || 50
        }
      end

      def parse_method_config(cfg)
        unless cfg.is_a?(Hash)
          raise ArgumentError, 'grpc.service_config: methodConfig entries must be objects'
        end
        retry_policy = parse_retry_policy(cfg['retryPolicy'])
        hedging_policy = parse_hedging_policy(cfg['hedgingPolicy'])
        if retry_policy && hedging_policy
          raise ArgumentError,
                'grpc.service_config: methodConfig cannot carry both a retryPolicy and a hedgingPolicy'
        end
        config = MethodConfig.new(parse_duration(cfg['timeout']), retry_policy,
                                  hedging_policy, cfg['waitForReady'])
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
                        status_codes(policy['retryableStatusCodes']))
      rescue TypeError, ArgumentError => e
        raise ArgumentError, "grpc.service_config has a malformed retryPolicy: #{e.message}"
      end

      # hedgingDelay has no per-attempt backoff: every hedge fires that
      # many seconds after the last, on a fixed schedule that does not
      # depend on how (or whether) earlier attempts have failed.
      def parse_hedging_policy(policy)
        return nil if policy.nil?
        unless policy.is_a?(Hash)
          raise ArgumentError, 'grpc.service_config: hedgingPolicy must be an object'
        end
        HedgingPolicy.new(Integer(require_field(policy, 'maxAttempts')),
                          parse_duration(require_field(policy, 'hedgingDelay')),
                          status_codes(policy['nonFatalStatusCodes']))
      rescue TypeError, ArgumentError => e
        raise ArgumentError, "grpc.service_config has a malformed hedgingPolicy: #{e.message}"
      end

      def require_field(policy, field)
        value = policy[field]
        raise ArgumentError, "missing #{field}" if value.nil?
        value
      end

      # Shared by retryableStatusCodes and nonFatalStatusCodes: both are
      # JSON arrays of status-code names.
      def status_codes(names)
        Array(names).map do |name|
          STATUS_CODES_BY_NAME.fetch(name) do
            raise ArgumentError, "has an unknown status code #{name.inspect}"
          end
        end
      end
    end
  end
end
