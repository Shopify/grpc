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

require 'spec_helper'

# A gRPC deadline is absolute. A status that reaches the client after the
# deadline has already passed must not turn a timed out RPC into a successful
# one, however narrowly it lost the race.
describe GRPC::Core::RpcStream, 'deadline ordering' do
  let(:stream) do
    described_class.new(nil, 1, max_receive_message_length: -1)
  end

  def now
    GRPC::Core::RpcStream.now
  end

  describe '#unfinished_at?' do
    it 'is false when there is no deadline' do
      expect(stream.unfinished_at?(nil)).to be false
    end

    it 'is true while the stream is still running' do
      expect(stream.unfinished_at?(now + 10)).to be true
    end

    it 'is false for trailers that arrived before the deadline' do
      stream.push_trailers([%w[grpc-status 0]])
      expect(stream.unfinished_at?(now + 10)).to be false
    end

    it 'is true for trailers that arrived after the deadline' do
      deadline = now - 0.01 # already expired
      stream.push_trailers([%w[grpc-status 0]])
      expect(stream.unfinished_at?(deadline)).to be true
    end

    it 'keeps the first termination instant' do
      deadline = now + 10
      stream.push_eos
      first = stream.instance_variable_get(:@terminated_at)
      sleep 0.02
      stream.push_trailers([%w[grpc-status 0]])
      expect(stream.instance_variable_get(:@terminated_at)).to eq(first)
      expect(stream.unfinished_at?(deadline)).to be false
    end

    it 'records a failure as a termination' do
      deadline = now - 0.01
      stream.push_failure(GRPC::Core::StatusCodes::UNAVAILABLE, 'gone')
      expect(stream.unfinished_at?(deadline)).to be true
    end
  end

  describe 'status resolution' do
    # Drives Call#resolve_client_status directly, so the ordering under test
    # is exact rather than left to a race between two processes.
    def status_for(deadline_offset:, trailers:)
      call = GRPC::Core::Call.allocate
      call.instance_variable_set(:@mu, Mutex.new)
      call.instance_variable_set(:@cancelled, nil)
      call.instance_variable_set(:@transport_failure, nil)
      call.instance_variable_set(:@stream, stream)
      call.instance_variable_set(:@monotonic_deadline, now + deadline_offset)
      stream.push_trailers(trailers) if trailers
      call.send(:resolve_client_status)
    end

    it 'reports OK for trailers that beat the deadline' do
      status = status_for(deadline_offset: 10, trailers: [%w[grpc-status 0]])
      expect(status.code).to eq(GRPC::Core::StatusCodes::OK)
    end

    it 'reports DEADLINE_EXCEEDED for OK trailers that arrive too late' do
      status = status_for(deadline_offset: -0.01, trailers: [%w[grpc-status 0]])
      expect(status.code).to eq(GRPC::Core::StatusCodes::DEADLINE_EXCEEDED)
      expect(status.details).to eq('Deadline Exceeded')
    end

    it 'still reports DEADLINE_EXCEEDED when no trailers arrive at all' do
      status = status_for(deadline_offset: -0.01, trailers: nil)
      expect(status.code).to eq(GRPC::Core::StatusCodes::DEADLINE_EXCEEDED)
    end

    it 'passes a real error status through when it beat the deadline' do
      status = status_for(deadline_offset: 10,
                          trailers: [%w[grpc-status 5], %w[grpc-message gone]])
      expect(status.code).to eq(GRPC::Core::StatusCodes::NOT_FOUND)
    end
  end
end
