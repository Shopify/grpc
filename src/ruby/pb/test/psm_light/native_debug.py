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
"""Stand-in for tests/fork/native_debug.pyx in the Python interop images.

The real module is a Cython extension that Bazel builds to install a native
crash-signal handler. The xDS interop scripts import it unconditionally. The
images run those scripts on pip wheels without Bazel, so this supplies the
same function as a no-op; it is a debugging aid the suites never exercise.
"""


def install_failure_signal_handler(**kwargs):
    del kwargs
