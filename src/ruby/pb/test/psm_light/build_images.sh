#!/usr/bin/env bash
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
#
# Builds the four images upstream's PSM Light suites (grpc/psm-interop
# tests/fallback_test.py and tests/federation_test.py) need, all locally:
# upstream publishes them only to a registry that needs grpc-testing
# credentials.
#
#   psm-local/test-control-plane:latest  psm-interop's Go control plane
#   psm-local/python-server:latest       this repo's Python xDS interop server
#   psm-local/python-client:latest       this repo's Python xDS interop client
#   psm-local/ruby-client:latest         this repo's Ruby xDS interop client
#
# The Python images stand in for upstream's canonical Java server and give
# a positive control: run a suite with python-client before blaming Ruby.
# They use released grpcio wheels, so nothing under test builds them.
#
# Usage: build_images.sh <psm-interop checkout> [control-plane|python|ruby]...
# With no image names, builds all of them.
set -euo pipefail

PSM_INTEROP_DIR="$(cd "${1:?Usage: build_images.sh <psm-interop checkout> [control-plane|python|ruby]...}" && pwd)"
shift
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../../../.." && pwd)"
WHICH=("$@")
[[ ${#WHICH[@]} -eq 0 ]] && WHICH=(control-plane python ruby)

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

build_control_plane() {
  # Upstream's Dockerfile, with three deltas applied here rather than kept
  # in a vendored copy, so this recipe follows upstream as it changes:
  # 1. protoc for the build host's architecture, not always x86_64;
  # 2. protoc-gen-go and protoc-gen-go-grpc pinned to the versions that
  #    match its go.mod, because @latest now needs a newer Go than the
  #    golang:1.22 image it builds on;
  # 3. `rm -rf grpc`, because a clean checkout has no generated grpc/ to
  #    remove and `rm -r` fails the build.
  local arch
  arch="$(docker info --format '{{.Architecture}}')"
  local zip_arch=x86_64
  [[ "${arch}" == aarch64 || "${arch}" == arm64 ]] && zip_arch=aarch_64
  sed -e "s/protoc-27.2-linux-x86_64.zip/protoc-27.2-linux-${zip_arch}.zip/" \
      -e 's#protoc-gen-go@latest#protoc-gen-go@v1.34.2#' \
      -e 's#protoc-gen-go-grpc@latest#protoc-gen-go-grpc@v1.4.0#' \
      -e 's/^RUN rm -r grpc$/RUN rm -rf grpc/' \
      "${PSM_INTEROP_DIR}/docker/test-control-plane/Dockerfile" > "${STAGE}/control-plane.Dockerfile"
  docker build -t psm-local/test-control-plane:latest \
    -f "${STAGE}/control-plane.Dockerfile" "${PSM_INTEROP_DIR}"
}

build_python() {
  local ctx="${STAGE}/python"
  local interop=src/python/grpcio_tests/tests_py3_only/interop
  mkdir -p "${ctx}/src/proto/grpc/testing" "${ctx}/${interop}" \
           "${ctx}/src/python/grpcio_tests/tests/fork"
  cp "${REPO}"/src/proto/grpc/testing/{empty,messages,test}.proto "${ctx}/src/proto/grpc/testing/"
  cp "${REPO}/${interop}/xds_interop_server.py" "${REPO}/${interop}/xds_interop_client.py" "${ctx}/${interop}/"
  cp "${HERE}/native_debug.py" "${ctx}/src/python/grpcio_tests/tests/fork/native_debug.py"
  cp "${HERE}/python-requirements.txt" "${ctx}/requirements.txt"
  local role
  for role in server client; do
    docker build -t "psm-local/python-${role}:latest" \
      --build-arg "ENTRY_SCRIPT=xds_interop_${role}.py" \
      -f "${HERE}/python.Dockerfile" "${ctx}"
  done
}

build_ruby() {
  # Only what the client loads, laid out at the repository's own relative
  # depth: grpc.rb finds etc/roots.pem relative to its own path.
  local ctx="${STAGE}/ruby"
  mkdir -p "${ctx}/etc" "${ctx}/src/ruby"
  cp "${REPO}/etc/roots.pem" "${ctx}/etc/"
  cp -R "${REPO}/src/ruby/lib" "${ctx}/src/ruby/lib"
  cp -R "${REPO}/src/ruby/pb" "${ctx}/src/ruby/pb"
  rm -rf "${ctx}/src/ruby/pb/test/xds_conformance" "${ctx}/src/ruby/pb/test/psm_light"
  docker build -t psm-local/ruby-client:latest -f "${HERE}/ruby-client.Dockerfile" "${ctx}"
}

for image in "${WHICH[@]}"; do
  case "${image}" in
    control-plane) build_control_plane ;;
    python) build_python ;;
    ruby) build_ruby ;;
    *) echo "unknown image: ${image} (want control-plane, python or ruby)" >&2; exit 1 ;;
  esac
done
