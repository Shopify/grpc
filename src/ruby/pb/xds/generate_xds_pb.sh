#!/bin/sh
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

# Regenerates the pure Ruby *message* classes the xDS client (grpc/core/
# xds_client.rb) decodes: DiscoveryRequest/Response, and the Listener,
# RouteConfiguration, Cluster and ClusterLoadAssignment resource types plus
# every proto they transitively import. No service stubs are generated --
# the ADS stream is a plain bidi call driven through
# GRPC::ClientStub#bidi_streamer against the method path
# "/envoy.service.discovery.v3.AggregatedDiscoveryService/StreamAggregatedResources",
# so protoc-gen-grpc has nothing to contribute here.
#
# The file list below is the full transitive closure of the six top-level
# .proto files, resolved by walking their `import` statements; regenerate
# it (and this list) if a future top-level proto changes what it imports.
set -e
cd $(dirname $0)/../../../..

PROTOC=/opt/homebrew/bin/protoc

$PROTOC \
    -I third_party/envoy-api \
    -I third_party/xds \
    -I third_party/protoc-gen-validate \
    -I third_party/googleapis \
    -I third_party/protobuf/src \
    --ruby_out=src/ruby/pb/xds \
    envoy/annotations/deprecation.proto \
    envoy/config/accesslog/v3/accesslog.proto \
    envoy/config/cluster/v3/circuit_breaker.proto \
    envoy/config/cluster/v3/cluster.proto \
    envoy/config/cluster/v3/filter.proto \
    envoy/config/cluster/v3/outlier_detection.proto \
    envoy/config/common/mutation_rules/v3/mutation_rules.proto \
    envoy/config/core/v3/address.proto \
    envoy/config/core/v3/backoff.proto \
    envoy/config/core/v3/base.proto \
    envoy/config/core/v3/config_source.proto \
    envoy/config/core/v3/event_service_config.proto \
    envoy/config/core/v3/extension.proto \
    envoy/config/core/v3/grpc_service.proto \
    envoy/config/core/v3/health_check.proto \
    envoy/config/core/v3/http_uri.proto \
    envoy/config/core/v3/protocol.proto \
    envoy/config/core/v3/proxy_protocol.proto \
    envoy/config/core/v3/resolver.proto \
    envoy/config/core/v3/socket_cmsg_headers.proto \
    envoy/config/core/v3/socket_option.proto \
    envoy/config/core/v3/substitution_format_string.proto \
    envoy/config/core/v3/udp_socket_config.proto \
    envoy/config/endpoint/v3/endpoint.proto \
    envoy/config/endpoint/v3/endpoint_components.proto \
    envoy/config/listener/v3/api_listener.proto \
    envoy/config/listener/v3/listener.proto \
    envoy/config/listener/v3/listener_components.proto \
    envoy/config/listener/v3/quic_config.proto \
    envoy/config/listener/v3/udp_listener_config.proto \
    envoy/config/route/v3/route.proto \
    envoy/config/route/v3/route_components.proto \
    envoy/config/route/v3/scoped_route.proto \
    envoy/config/trace/v3/http_tracer.proto \
    envoy/data/accesslog/v3/accesslog.proto \
    envoy/extensions/filters/network/http_connection_manager/v3/http_connection_manager.proto \
    envoy/service/discovery/v3/ads.proto \
    envoy/service/discovery/v3/discovery.proto \
    envoy/type/http/v3/path_transformation.proto \
    envoy/type/matcher/v3/address.proto \
    envoy/type/matcher/v3/filter_state.proto \
    envoy/type/matcher/v3/metadata.proto \
    envoy/type/matcher/v3/number.proto \
    envoy/type/matcher/v3/regex.proto \
    envoy/type/matcher/v3/string.proto \
    envoy/type/matcher/v3/value.proto \
    envoy/type/metadata/v3/metadata.proto \
    envoy/type/tracing/v3/custom_tag.proto \
    envoy/type/v3/http.proto \
    envoy/type/v3/percent.proto \
    envoy/type/v3/range.proto \
    envoy/type/v3/semantic_version.proto \
    google/rpc/status.proto \
    udpa/annotations/migrate.proto \
    udpa/annotations/security.proto \
    udpa/annotations/sensitive.proto \
    udpa/annotations/status.proto \
    udpa/annotations/versioning.proto \
    validate/validate.proto \
    xds/annotations/v3/status.proto \
    xds/core/v3/authority.proto \
    xds/core/v3/cidr.proto \
    xds/core/v3/collection_entry.proto \
    xds/core/v3/context_params.proto \
    xds/core/v3/extension.proto \
    xds/core/v3/resource_locator.proto \
    xds/type/matcher/v3/matcher.proto \
    xds/type/matcher/v3/regex.proto \
    xds/type/matcher/v3/string.proto

# google/protobuf/{any,duration,struct,wrappers,...}.proto are NOT
# generated here: the google-protobuf gem already ships pure Ruby classes
# for every well-known type, and generating a second copy under
# src/ruby/pb/xds/google/protobuf would shadow (or conflict with) them on
# the load path.
