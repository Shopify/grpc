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
# Runs one of upstream's PSM Light suites, unmodified, against a client
# image built by build_images.sh. No GKE and no GCP project are involved.
#
# Usage:
#   PSM_INTEROP_DIR=<checkout> run.sh <client image> <fallback_test|federation_test> [Class.test]
#
# PSM_INTEROP_DIR is a grpc/psm-interop checkout with a Python 3.10+ venv
# at $PSM_INTEROP_DIR/venv (or $PSM_VENV) and its protos generated, as its
# README describes.
set -euo pipefail

CLIENT_IMAGE="${1:?Usage: run.sh <client image> <fallback_test|federation_test> [Class.test]}"
TEST_NAME="${2:?Usage: run.sh <client image> <fallback_test|federation_test> [Class.test]}"
TEST_FILTER="${3:-}"
case "${TEST_NAME}" in
  fallback_test|federation_test) ;;
  *) echo "unknown suite: ${TEST_NAME} (want fallback_test or federation_test)" >&2; exit 1 ;;
esac

PSM_INTEROP_DIR="$(cd "${PSM_INTEROP_DIR:?set PSM_INTEROP_DIR to a grpc/psm-interop checkout}" && pwd)"
PYTHON="${PSM_VENV:-${PSM_INTEROP_DIR}/venv}/bin/python"
[[ -x "${PYTHON}" ]] || { echo "no psm-interop venv at ${PYTHON%/bin/python}" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# docker-py reads DOCKER_HOST and ignores `docker context`.
if [[ -z "${DOCKER_HOST:-}" ]]; then
  DOCKER_HOST="$(docker context inspect --format '{{.Endpoints.docker.Host}}')"
  export DOCKER_HOST
fi

# Every container bind-mounts the bootstrap directory, which the driver
# creates under --log_dir. A VM-backed Docker (Colima, Docker Desktop)
# shares $HOME into the VM but not necessarily /tmp, so logs live there.
LOG_DIR="${PSM_LOG_DIR:-${HOME}/.cache/grpc-psm-light}/$(date +%Y%m%d_%H%M%S)"
mkdir -p "${LOG_DIR}"

# The suites put socket.gethostbyname(socket.gethostname()) into every EDS
# endpoint, meaning "an address the containers can reach this host on".
# Some networks resolve the host's own name to loopback, which a container
# cannot use. Then use host.docker.internal, which the suites already use
# for the control planes, through sitecustomize.py.
HOST_IP="$("${PYTHON}" -c 'import socket; print(socket.gethostbyname(socket.gethostname()))' 2>/dev/null || true)"
if [[ -z "${HOST_IP}" || "${HOST_IP}" == 127.* ]]; then
  PSM_HOST_IP="$(docker run --rm alpine:3 getent hosts host.docker.internal | awk '{print $1; exit}')"
  if [[ -z "${PSM_HOST_IP}" || "${PSM_HOST_IP}" == 127.* ]]; then
    echo "no container-reachable address for this host (own name: '${HOST_IP}', host.docker.internal: '${PSM_HOST_IP}')" >&2
    exit 1
  fi
  export PSM_HOST_IP
  export PYTHONPATH="${HERE}/pyshim${PYTHONPATH:+:${PYTHONPATH}}"
  HOST_IP="${PSM_HOST_IP}"
fi
echo "EDS endpoints will use ${HOST_IP}"

FLAGS=(
  --flagfile=config/common.cfg
  --flagfile=config/common-light.cfg
  # Required by the flags these suites adopt from the GKE framework; the
  # Docker-based suites never use them.
  --project=psm-light-local
  --resource_prefix=psm-light-local
  --kube_context=psm-light-local
  "--client_image=${CLIENT_IMAGE}"
  --server_image=psm-local/python-server:latest
  --server_image_canonical=psm-local/python-server:latest
  --control_plane_image=psm-local/test-control-plane:latest
  "--log_dir=${LOG_DIR}"
  "--xml_output_file=${LOG_DIR}/sponge_log.xml"
)
[[ -n "${TEST_FILTER}" ]] && FLAGS+=("${TEST_FILTER}")

set +e
(cd "${PSM_INTEROP_DIR}" && "${PYTHON}" -m "tests.${TEST_NAME}" "${FLAGS[@]}") 2>&1 | tee "${LOG_DIR}/test_driver.log"
status="${PIPESTATUS[0]}"
set -e
echo "logs: ${LOG_DIR}"
exit "${status}"
