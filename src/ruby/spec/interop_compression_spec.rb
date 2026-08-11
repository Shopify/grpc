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

require 'spec_helper'

# server.rb (like client.rb) is a standalone script that, at require time,
# unconditionally calls `module GRPC; extend RubyLogger; end` to give itself
# a plain STDOUT logger. Loaded here for TestTarget and the helper methods
# under test, that would otherwise permanently replace the `Logging`-backed
# GRPC.logger spec_helper.rb sets up (see its `GRPC.logger =` docs), which
# is what feeds every other spec's captured @log_output. Save and restore it
# around the require so this file has no effect on the rest of the suite.
original_grpc_logger = GRPC.logger
require_relative '../pb/test/server'
GRPC.logger = original_grpc_logger

# Covers the interop test server's handling of SimpleRequest/
# StreamingInputCallRequest#expect_compressed and SimpleRequest
# #response_compressed (doc/interop-test-descriptions.md's "CompressedRequest"
# and "CompressedResponse" sections). Before this file, nothing exercised
# these: the client_compressed_unary and client_compressed_streaming interop
# cases open with a probe that requires an INVALID_ARGUMENT the server never
# sent, so upstream's tools/run_tests/run_interop_tests.py listed every
# compression case as unimplemented on the Ruby server. That made this port's
# gzip/deflate message framing untested against anything but itself.
# A minimal stand-in for GRPC::Core::Call/ActiveCall, sized to exactly what
# #check_expect_compressed! and #maybe_set_response_compression touch.
FakeCall = Struct.new(:message_compressed, :send_encoding)

describe 'interop test server compression handling' do
  include GRPC::Spec::Helpers

  describe '#check_expect_compressed!' do
    it 'is a no-op when the client did not set expect_compressed' do
      expect { check_expect_compressed!(nil, true) }.to_not raise_error
      expect { check_expect_compressed!(nil, false) }.to_not raise_error
    end

    it 'passes when the wire matched what was expected' do
      expect { check_expect_compressed!(Grpc::Testing::BoolValue.new(value: true), true) }
        .to_not raise_error
      expect { check_expect_compressed!(Grpc::Testing::BoolValue.new(value: false), false) }
        .to_not raise_error
    end

    it 'raises INVALID_ARGUMENT when compression was expected but the message arrived uncompressed' do
      expect { check_expect_compressed!(Grpc::Testing::BoolValue.new(value: true), false) }
        .to raise_error(GRPC::BadStatus) { |e| expect(e.code).to eq(GRPC::Core::StatusCodes::INVALID_ARGUMENT) }
    end

    it 'raises INVALID_ARGUMENT when compression was not expected but the message arrived compressed' do
      expect { check_expect_compressed!(Grpc::Testing::BoolValue.new(value: false), true) }
        .to raise_error(GRPC::BadStatus) { |e| expect(e.code).to eq(GRPC::Core::StatusCodes::INVALID_ARGUMENT) }
    end
  end

  describe '#maybe_set_response_compression' do
    it 'leaves the call alone when response_compressed is unset' do
      call = FakeCall.new(false, 'identity')
      maybe_set_response_compression(call, nil)
      expect(call.send_encoding).to eq('identity')
    end

    it 'asks for gzip when response_compressed is true' do
      call = FakeCall.new(false, 'identity')
      maybe_set_response_compression(call, Grpc::Testing::BoolValue.new(value: true))
      expect(call.send_encoding).to eq('gzip')
    end

    it 'forces identity when response_compressed is false' do
      call = FakeCall.new(false, 'identity')
      maybe_set_response_compression(call, Grpc::Testing::BoolValue.new(value: false))
      expect(call.send_encoding).to eq('identity')
    end
  end

  # RpcStream is where the wire's per-message compression bit is actually
  # read; this is the plumbing #check_expect_compressed! above relies on.
  describe 'GRPC::Core::RpcStream#last_message_compressed' do
    let(:stream) do
      GRPC::Core::RpcStream.new(nil, 1, max_receive_message_length: 1 << 20)
    end

    def framed(body, compressed:)
      [compressed ? 1 : 0, body.bytesize].pack('CN') + body
    end

    it 'is true for a message with the compressed frame bit set' do
      body = Zlib::Deflate.deflate('hello')
      stream.push_data(framed(body, compressed: true))
      stream.read_message(nil)
      expect(stream.last_message_compressed).to be true
    end

    it 'is false for a message with the compressed frame bit clear' do
      stream.push_data(framed('hello', compressed: false))
      stream.read_message(nil)
      expect(stream.last_message_compressed).to be false
    end
  end

  # End to end: the exact probe/real-call sequence client_compressed_unary
  # and client_compressed_streaming perform against a real TestTarget over a
  # real socket, so a regression in the ActiveCall/view plumbing (not just
  # the two helpers above) would fail this too.
  describe 'end to end, against a real TestTarget server' do
    def gzip_stub
      build_insecure_stub(
        Grpc::Testing::TestService::Stub,
        opts: { channel_args: {
          'grpc.default_compression_algorithm' =>
            GRPC::Core::CompressionOptions::ALGORITHM_VALUES[:gzip]
        } })
    end

    before(:each) do
      build_rpc_server
    end

    it 'unary: rejects the identity-forced probe that lies about expect_compressed' do
      run_services_on_server(@server, services: [TestTarget]) do
        stub = build_insecure_stub(Grpc::Testing::TestService::Stub)
        req = Grpc::Testing::SimpleRequest.new(
          response_size: 1,
          payload: Grpc::Testing::Payload.new(body: 'x'),
          expect_compressed: Grpc::Testing::BoolValue.new(value: true)
        )
        expect { stub.unary_call(req) }.to raise_error(GRPC::BadStatus) do |e|
          expect(e.code).to eq(GRPC::Core::StatusCodes::INVALID_ARGUMENT)
        end
      end
    end

    it 'unary: succeeds when the request really is compressed and expect_compressed is true' do
      run_services_on_server(@server, services: [TestTarget]) do
        req = Grpc::Testing::SimpleRequest.new(
          response_size: 5,
          payload: Grpc::Testing::Payload.new(body: 'x' * 1000),
          expect_compressed: Grpc::Testing::BoolValue.new(value: true)
        )
        resp = gzip_stub.unary_call(req)
        expect(resp.payload.body.length).to eq(5)
      end
    end

    it 'unary: succeeds when the request is uncompressed and expect_compressed is false' do
      run_services_on_server(@server, services: [TestTarget]) do
        stub = build_insecure_stub(Grpc::Testing::TestService::Stub)
        req = Grpc::Testing::SimpleRequest.new(
          response_size: 5,
          payload: Grpc::Testing::Payload.new(body: 'x'),
          expect_compressed: Grpc::Testing::BoolValue.new(value: false)
        )
        resp = stub.unary_call(req)
        expect(resp.payload.body.length).to eq(5)
      end
    end

    it 'streaming: rejects a message that lied about expect_compressed' do
      run_services_on_server(@server, services: [TestTarget]) do
        stub = build_insecure_stub(Grpc::Testing::TestService::Stub)
        req = Grpc::Testing::StreamingInputCallRequest.new(
          payload: Grpc::Testing::Payload.new(body: 'x'),
          expect_compressed: Grpc::Testing::BoolValue.new(value: true)
        )
        expect { stub.streaming_input_call([req]) }.to raise_error(GRPC::BadStatus) do |e|
          expect(e.code).to eq(GRPC::Core::StatusCodes::INVALID_ARGUMENT)
        end
      end
    end

    it 'streaming: succeeds when each message matches its own expect_compressed' do
      run_services_on_server(@server, services: [TestTarget]) do
        req = Grpc::Testing::StreamingInputCallRequest.new(
          payload: Grpc::Testing::Payload.new(body: 'x' * 1000),
          expect_compressed: Grpc::Testing::BoolValue.new(value: true)
        )
        resp = gzip_stub.streaming_input_call([req])
        expect(resp.aggregated_payload_size).to eq(1000)
      end
    end
  end
end
