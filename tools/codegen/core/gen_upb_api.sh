#!/bin/bash

# Copyright 2016 gRPC authors.
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

set -ex

cd $(dirname $0)/../../..
bazel=`pwd`/tools/bazel

if [ $# -eq 0 ]; then
  UPB_OUTPUT_DIR=$PWD/src/core/ext/upb-generated
  rm -rf $UPB_OUTPUT_DIR
  mkdir -p $UPB_OUTPUT_DIR
else
  UPB_OUTPUT_DIR=$1
fi

$bazel build @com_google_protobuf//:protoc
PROTOC=$PWD/bazel-bin/external/com_google_protobuf/protoc

$bazel build @upb//:protoc-gen-upb
UPB_PLUGIN=$PWD/bazel-bin/external/upb/protoc-gen-upb

proto_files=( \
  "envoy/annotations/deprecation.proto" \
  "envoy/annotations/resource.proto" \
  "envoy/config/accesslog/v3/accesslog.proto" \
  "envoy/config/cluster/v3/circuit_breaker.proto" \
  "envoy/config/cluster/v3/cluster.proto" \
  "envoy/config/cluster/v3/filter.proto" \
  "envoy/config/cluster/v3/outlier_detection.proto" \
  "envoy/config/core/v3/address.proto" \
  "envoy/config/core/v3/backoff.proto" \
  "envoy/config/core/v3/base.proto" \
  "envoy/config/core/v3/config_source.proto" \
  "envoy/config/core/v3/event_service_config.proto" \
  "envoy/config/core/v3/grpc_service.proto" \
  "envoy/config/core/v3/health_check.proto" \
  "envoy/config/core/v3/http_uri.proto" \
  "envoy/config/core/v3/protocol.proto" \
  "envoy/config/core/v3/proxy_protocol.proto" \
  "envoy/config/core/v3/socket_option.proto" \
  "envoy/config/endpoint/v3/endpoint.proto" \
  "envoy/config/endpoint/v3/endpoint_components.proto" \
  "envoy/config/endpoint/v3/load_report.proto" \
  "envoy/config/listener/v3/api_listener.proto" \
  "envoy/config/listener/v3/listener.proto" \
  "envoy/config/listener/v3/listener_components.proto" \
  "envoy/config/listener/v3/udp_listener_config.proto" \
  "envoy/config/rbac/v3/rbac.proto" \
  "envoy/config/route/v3/route.proto" \
  "envoy/config/route/v3/route_components.proto" \
  "envoy/config/route/v3/scoped_route.proto" \
  "envoy/config/trace/v3/http_tracer.proto" \
  "envoy/extensions/filters/network/http_connection_manager/v3/http_connection_manager.proto" \
  "envoy/extensions/transport_sockets/tls/v3/cert.proto" \
  "envoy/extensions/transport_sockets/tls/v3/common.proto" \
  "envoy/extensions/transport_sockets/tls/v3/secret.proto" \
  "envoy/extensions/transport_sockets/tls/v3/tls.proto" \
  "envoy/service/cluster/v3/cds.proto" \
  "envoy/service/discovery/v3/ads.proto" \
  "envoy/service/discovery/v3/discovery.proto" \
  "envoy/service/endpoint/v3/eds.proto" \
  "envoy/service/listener/v3/lds.proto" \
  "envoy/service/load_stats/v3/lrs.proto" \
  "envoy/service/route/v3/rds.proto" \
  "envoy/service/route/v3/srds.proto" \
  "envoy/type/matcher/v3/metadata.proto" \
  "envoy/type/matcher/v3/number.proto" \
  "envoy/type/matcher/v3/path.proto" \
  "envoy/type/matcher/v3/regex.proto" \
  "envoy/type/matcher/v3/string.proto" \
  "envoy/type/matcher/v3/value.proto" \
  "envoy/type/metadata/v3/metadata.proto" \
  "envoy/type/tracing/v3/custom_tag.proto" \
  "envoy/type/v3/http.proto" \
  "envoy/type/v3/percent.proto" \
  "envoy/type/v3/range.proto" \
  "envoy/type/v3/semantic_version.proto" \
  "gogoproto/gogo.proto" \
  "google/api/annotations.proto" \
  "google/api/expr/v1alpha1/syntax.proto" \
  "google/api/http.proto" \
  "google/protobuf/any.proto" \
  "google/protobuf/descriptor.proto" \
  "google/protobuf/duration.proto" \
  "google/protobuf/empty.proto" \
  "google/protobuf/struct.proto" \
  "google/protobuf/timestamp.proto" \
  "google/protobuf/wrappers.proto" \
  "google/rpc/status.proto" \
  "src/proto/grpc/gcp/altscontext.proto" \
  "src/proto/grpc/gcp/handshaker.proto" \
  "src/proto/grpc/gcp/transport_security_common.proto" \
  "src/proto/grpc/health/v1/health.proto" \
  "src/proto/grpc/lb/v1/load_balancer.proto" \
  "udpa/data/orca/v1/orca_load_report.proto" \
  "udpa/annotations/migrate.proto" \
  "udpa/annotations/sensitive.proto" \
  "udpa/annotations/status.proto" \
  "udpa/annotations/versioning.proto" \
  "validate/validate.proto")

for i in "${proto_files[@]}"
do
  echo "Compiling: ${i}"
  $PROTOC \
    -I=$PWD/third_party/udpa \
    -I=$PWD/third_party/envoy-api \
    -I=$PWD/third_party/googleapis \
    -I=$PWD/third_party/protobuf/src \
    -I=$PWD/third_party/protoc-gen-validate \
    -I=$PWD \
    $i \
    --upb_out=$UPB_OUTPUT_DIR \
    --plugin=protoc-gen-upb=$UPB_PLUGIN
done

find $UPB_OUTPUT_DIR -name "*.upbdefs.c" -type f -delete
find $UPB_OUTPUT_DIR -name "*.upbdefs.h" -type f -delete
