# frozen_string_literal: true

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

module GRPC
  module Core
    class XdsClient
      # Per-cluster call outcome counts for LRS (gRFC A45-ish load
      # reporting). A Transport::Target for a cluster that requested load
      # reporting (Cluster#lrs_server pointing at "self") carries one of
      # these; Subchannel forwards it to whatever Connection it dials, and
      # Call#start_client_call/#op_recv_status bump it -- the same
      # lock-free, allocation-free trade OutlierDetection::CallCounter
      # makes, for the same reason: a mutex on this path measured 12 per
      # cent slower on the eight-thread benchmark. #snapshot! (called once
      # per load_reporting_interval, from AdsConnection's LRS stream) is
      # the only place these racy increments are ever read.
      class LrsCallCounter
        def initialize
          @issued = 0
          @success = 0
          @failure = 0
          @in_progress = 0
        end

        # Bumped once when a call actually starts sending on this
        # subchannel -- see Call#start_client_call.
        def record_issued
          @issued += 1
          @in_progress += 1
        end

        # Bumped once when a call finishes, however it finishes (trailers,
        # cancellation, transport failure, deadline) -- see
        # Call#op_recv_status.
        def record_finished(succeeded)
          @in_progress -= 1
          succeeded ? @success += 1 : @failure += 1
        end

        # [issued, successful, failed, in_progress] for the interval that
        # just ended; issued/successful/failed reset to zero (LRS load
        # reports are per-interval deltas), but in_progress is a live
        # gauge -- a call still in flight when this snapshot is taken is
        # still in flight for the next one too, so it is not zeroed.
        def snapshot!
          issued = @issued
          success = @success
          failure = @failure
          @issued = 0
          @success = 0
          @failure = 0
          [issued, success, failure, @in_progress]
        end
      end
    end
  end
end
