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

# The pure-Ruby xDS interop client, src/ruby/pb/test/xds_client.rb. Build
# it with build_images.sh, which stages only what the client loads.
FROM ruby:4.0-slim

# grpc.gemspec's runtime dependencies.
RUN gem install --no-document google-protobuf -v ">= 3.25, < 5.0" && \
    gem install --no-document googleapis-common-protos-types -v "~> 1.0"

# Not /grpc: the suites bind-mount the bootstrap directory there, over
# whatever the image put at that path.
WORKDIR /app
COPY etc ./etc
COPY src ./src

ENV RUBYOPT="-Isrc/ruby/lib -Isrc/ruby/pb"
ENTRYPOINT ["ruby", "src/ruby/pb/test/xds_client.rb"]
