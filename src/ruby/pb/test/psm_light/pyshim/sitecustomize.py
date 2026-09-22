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
"""Loaded into the psm-interop driver by run.sh, and only when needed.

The suites put socket.gethostbyname(socket.gethostname()) into every EDS
endpoint, meaning an address the containers can reach this host on. When the
host's own name resolves to loopback, run.sh sets PSM_HOST_IP to the address
containers use for the host, and this answers that one lookup with it. Every
other lookup is untouched.
"""
import os
import socket

_HOST_IP = os.environ.get("PSM_HOST_IP")
if _HOST_IP:
    _OWN_NAME = socket.gethostname()
    _ORIGINAL = socket.gethostbyname

    def gethostbyname(name):
        if name == _OWN_NAME:
            return _HOST_IP
        return _ORIGINAL(name)

    socket.gethostbyname = gethostbyname
