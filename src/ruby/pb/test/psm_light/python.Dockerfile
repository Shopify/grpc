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

# This repo's Python xDS interop server or client, unmodified, on released
# grpcio wheels. ENTRY_SCRIPT picks which; build_images.sh builds both.
FROM python:3.11-slim-bookworm

ARG ENTRY_SCRIPT=xds_interop_server.py
ENV ENTRY_SCRIPT=${ENTRY_SCRIPT}
ENV PYTHONUNBUFFERED=1
ENV PYTHONPATH=/app
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src ./src
# The scripts import the generated code as src.proto.grpc.testing.*.
RUN python -m grpc_tools.protoc --proto_path=. --python_out=. --grpc_python_out=. \
    src/proto/grpc/testing/empty.proto \
    src/proto/grpc/testing/messages.proto \
    src/proto/grpc/testing/test.proto

ENTRYPOINT ["sh", "-c", "exec python -u \"/app/src/python/grpcio_tests/tests_py3_only/interop/${ENTRY_SCRIPT}\" \"$@\"", "--"]
