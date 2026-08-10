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

# Two header values are read a byte at a time rather than through a regexp,
# to keep the substrings a match would allocate off the request path. These
# pin the behaviour that replaced.
describe 'header values parsed without intermediate strings' do
  describe 'GRPC::Core::Server#deadline_from' do
    let(:parse) do
      server = GRPC::Core::Server.allocate
      GRPC::Core::Server.instance_method(:deadline_from).bind(server)
    end

    # The exact sentinel, not merely a distant time: a malformed header must
    # not be read as a very long deadline.
    def no_deadline?(time)
      time.to_i == GRPC::Core::TimeSpec::INF_FUTURE_TIME_SEC
    end

    {
      '10S' => 10.0,
      '1M' => 60.0,
      '2H' => 7200.0,
      '1000m' => 1.0,
      '500u' => 0.0005,
      '0n' => 0.0,
      '99999999S' => 99_999_999.0
    }.each do |header, seconds|
      it "reads #{header.inspect} as #{seconds} seconds from now" do
        expect(parse.call(header) - Time.now).to be_within(1.0).of(seconds)
      end
    end

    # Anything the spec does not allow means no deadline, rather than an
    # exception on the request path.
    ['', 'S', 'abc', '10X', '1z', '-1S', '10 S', "10S\n",
     '999999999S', 'S10'].each do |header|
      it "treats #{header.inspect} as no deadline" do
        expect(no_deadline?(parse.call(header))).to be true
      end
    end

    it 'treats a missing header as no deadline' do
      expect(no_deadline?(parse.call(nil))).to be true
    end

    # It reaches user code through NewServerRpc#deadline and
    # ActiveCall#deadline, and Time#utc mutates its receiver.
    it 'returns a Time the caller may mutate' do
      deadline = parse.call(nil)
      expect { deadline.utc }.not_to raise_error
    end

    it 'returns a distinct Time each call' do
      expect(parse.call(nil)).not_to equal(parse.call(nil))
    end
  end

  describe 'grpc-message percent coding' do
    let(:call) { GRPC::Core::Call.allocate }
    let(:encode) do
      GRPC::Core::Call.instance_method(:percent_encode).bind(call)
    end
    let(:decode) do
      GRPC::Core::Call.instance_method(:percent_decode).bind(call)
    end

    # %x20-%x24 and %x26-%x7E travel as themselves; everything else, and '%'
    # itself, is escaped.
    {
      '' => '',
      'OK' => 'OK',
      'a b$c' => 'a b$c',
      '100% done' => '100%25 done',
      "tab\there" => 'tab%09here',
      "\x00\x01" => '%00%01',
      'héllo' => 'h%C3%A9llo'
    }.each do |raw, encoded|
      it "encodes #{raw.inspect} as #{encoded.inspect}" do
        expect(encode.call(raw).b).to eq(encoded.b)
      end

      it "decodes #{encoded.inspect} back to #{raw.inspect}" do
        expect(decode.call(encoded.dup.force_encoding(Encoding::UTF_8)).b)
          .to eq(raw.b)
      end
    end

    # Nothing to escape means the caller's own String comes back, which is
    # what keeps the common case free of allocation.
    it 'returns the same object when no byte needs escaping' do
      text = 'nothing to escape'
      expect(encode.call(text)).to equal(text)
    end

    it 'returns the same object when there is no escape to decode' do
      text = 'nothing to decode'
      expect(decode.call(text)).to equal(text)
    end

    # A truncated or malformed escape is left alone rather than raising.
    ['a%2', 'end%', '%zz', '%%'].each do |text|
      it "leaves #{text.inspect} alone when the escape is malformed" do
        expect(decode.call(text.dup.force_encoding(Encoding::UTF_8)).b)
          .to eq(text.b)
      end
    end

    it 'round trips every byte value' do
      raw = (0..255).to_a.pack('C*')
      expect(decode.call(encode.call(raw).force_encoding(Encoding::UTF_8)).b)
        .to eq(raw.b)
    end
  end
end
