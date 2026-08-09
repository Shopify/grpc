# The pure Ruby implementation of GRPC::Core

gRPC Ruby was a C extension that wrapped gRPC C-core. It is now written
in Ruby. This document records how the core is put together, what is
verified, and what is not done yet.

The wrapper layer above `GRPC::Core` did not change. `ClientStub`,
`RpcServer`, `ActiveCall` and `BidiCall` drive the same `GRPC::Core` API
as before.

## Layout

All of the core lives under `src/ruby/lib/grpc/core`.

| File | Responsibility |
| --- | --- |
| `call.rb` | `Core::Call`, and the `run_batch` operation set |
| `channel.rb` | `Core::Channel`, connection state, reconnection |
| `server.rb` | `Core::Server`, listeners, the accept path, shutdown |
| `connection.rb` | One HTTP/2 session, and the RPCs on it |
| `rpc_stream.rb` | One RPC: message framing, blocking reads, write backpressure |
| `transport.rb` | Target parsing, sockets, TLS with ALPN `h2` |
| `metadata.rb` | Metadata validation, and binary header encoding |
| `credentials.rb` | Channel, server and XDS credentials |
| `call_credentials.rb` | Per-call credentials and composition |
| `compression_options.rb`, `message_compression.rb` | Compression |
| `channel_args.rb`, `constants.rb`, `time_spec.rb` | Types and constants |
| `http2/kantan/` | Vendored HTTP/2 (see below) |

An RPC flows like this:

```
ClientStub -> Core::Call#run_batch -> Core::Channel#open_stream
           -> Core::Connection    -> Core::RpcStream
           -> Kantan::H2::Session -> socket
```

Each HTTP/2 session owns a reader thread and a writer thread. Session
callbacks run on the reader thread, so they only append to buffers and
signal. Application threads block in `RpcStream`, which is where every
deadline is applied.

## Vendored HTTP/2

`http2/kantan/` holds a copy of [kantan](https://github.com/tenderlove/kantan)
by Aaron Patterson. Kantan is Apache 2.0, the same licence as gRPC.
`NOTICE.txt` records this.

The copy sits in the `GRPC::Core::Http2` namespace, so it cannot collide
with a separately installed kantan gem. A `grpc:` comment marks each
local change. The changes are:

- HPACK integers are coded by hand. Kantan used the `R` pack directive,
  which Ruby 4.1 added, and gRPC supports Ruby 3.2 and later.
- The write path takes DATA chunks over the life of a stream and writes a
  trailing HEADERS block. A gRPC call needs both.
- A write acknowledgement lets a sender apply backpressure.
- A late `WINDOW_UPDATE` or `RST_STREAM` for a stream that this endpoint
  opened and finished is ignored, as RFC 7540 section 5.1 requires.
  Before, it failed the whole connection.
- The session reports the peer `SETTINGS` frame to its handler.
- The socket rescues cover every `SystemCallError` and TLS error.

Sizes: about 3500 lines of new code and 2300 lines of vendored code, in
place of about 6800 lines of C.

## Behaviour worth knowing

- **READY means the handshake finished.** A channel reports READY after
  the peer's first `SETTINGS` frame, not after the TCP connect. A peer
  can complete a socket into its backlog and never service it, and a
  channel must not call that transport usable.
- **Backpressure has a watermark.** `RpcStream#send_message` blocks only
  once more than 256 KiB is queued but not yet written. Waiting for every
  message costs a thread handoff per message.
- **Deadlines are absolute.** A status that arrives after the deadline
  has passed does not rescue the call. `RpcStream` records when the
  stream finished, and `Call#resolve_client_status` compares that instant
  with the deadline. Asking only whether any trailers turned up let a
  status that lost the race report success for an RPC that had timed out.
- **Windows are larger than the protocol default.** This endpoint
  advertises a 1 MiB stream window and raises the connection window to
  match with a `WINDOW_UPDATE` on stream 0 straight after the preface.
  The 65535 byte default makes a peer stop and wait on every 64 KiB
  message. The connection window is what bounds how much unread data one
  connection can hold.
- **Flow control is returned in blocks.** A `WINDOW_UPDATE` goes out once
  half the window is spent, not once per DATA frame. Every byte still has
  to be returned, including padding and including frames that are thrown
  away because the stream was reset, or the window drains for good and
  the connection stalls with no error anywhere.
- **Fork.** `GRPC.prefork` and `GRPC.postfork_parent` do nothing, because
  no process-wide native state exists any more. `GRPC.postfork_child`
  drops the transports the child inherited, because the child has the
  sockets but not the threads that drive them. The next RPC dials again.
  For a TLS socket the child closes the descriptor and not the session,
  because a `close_notify` alert would travel down the socket that the
  parent still uses.
- **Metadata errors still belong to the caller.** Bad metadata raises
  from `run_batch`. Metadata that a credentials plugin produced fails the
  RPC with `UNAVAILABLE`, which is what C-core did.
- **Logging is lazy, but not by passing blocks.** `GRPC.log_debug` and
  its siblings build the message only when a logger will take it, then
  hand it over positionally. `GRPC.logger` accepts any object a user
  supplies, and plenty of them define `debug(msg)` with a required
  argument, so calling the logger with a block and no argument raises.

## Verification

| Suite | How to run | State |
| --- | --- | --- |
| RSpec | `rspec -I src/ruby/lib -I src/ruby/spec -I src/ruby/pb src/ruby/spec` | 501 examples, 6 failures |
| End to end | run each `src/ruby/end2end/*_test.rb` | 23 of 24 |
| gRPC interop | `src/ruby/pb/test/{server,client}.rb` | 14 of 14, insecure and TLS |
| h2spec | point it at a server on the vendored session | 146 of 146, both write paths, 10 runs each |
| hpack-test-case | kantan's `test/test_hpack.rb` | 41 runs, 0 failures |
| RuboCop | `rake rubocop` | clean |

The six RSpec failures and the one end to end failure all shell out to
`cmake/build/grpc_ruby_plugin` and `cmake/build/third_party/protobuf/protoc`.
Those are C++ build artifacts. The tests compare generated `.rb` files
and never load the Ruby runtime. Build the plugin to run them.

The interop cases are the list in `tools/run_tests/run_interop_tests.py`,
less the ones that `RubyLanguage#unimplemented_test_cases_server` skips.
The authentication cases need real credentials, so they are not covered
here. Cross-language interop needs the Docker images that
`run_interop_tests.py` builds.

## Performance

Use `src/ruby/bench`. See its README for the method. Medians of five runs
on one arm64 macOS machine, against the precompiled grpc 1.83.0 gem,
under YJIT:

| Scenario | pure Ruby | C extension | ratio |
| --- | --- | --- | --- |
| unary, empty payload | 7561 qps | 6559 qps | 1.15 |
| unary, 64 KiB payload | 2816 qps | 3850 qps | 0.73 |
| unary, 8 threads | 15806 qps | 16111 qps | 0.98 |
| server streaming | 297584 msg/s | 52084 msg/s | 5.71 |
| client streaming | 296125 msg/s | 50762 msg/s | 5.83 |

### Why streaming is so far ahead

A factor of six deserves suspicion, so it was chased down. It is real, it
holds in steady state, and it is narrower than the headline.

The benchmark asserts delivery: both streaming scenarios count what the
peer actually received and fail the run if any is missing, and the same
check runs when the C extension is the peer. So a C extension process
independently counted every message arriving from this implementation.

Throughput is set by which side is *sending* and barely moves with the
receiver, at 1 KiB and 1000 messages a stream:

| | sender | receiver | msg/s |
| --- | --- | --- | --- |
| server streaming | pure Ruby | C extension | 295770 |
| server streaming | C extension | pure Ruby | 54064 |
| client streaming | pure Ruby | C extension | 304470 |
| client streaming | C extension | pure Ruby | 49156 |

It is not a warm up effect. At 100000 messages a stream the ratio holds,
and it falls away as messages get larger, which is what a fixed per
message overhead looks like:

| message | messages | pure Ruby | C extension | ratio |
| --- | --- | --- | --- | --- |
| 64 B | 100000 | 360458 msg/s | 58857 msg/s | 6.1 |
| 1 KiB | 100000 | 272207 msg/s | 52748 msg/s | 5.2 |
| 16 KiB | 20000 | 61524 msg/s | 42738 msg/s | 1.4 |

Fitting cost against size over those three points:

- pure Ruby: about 2.8 us per message plus 0.84 us per KiB
- C extension: about 17.8 us per message plus 0.36 us per KiB

So the C extension moves bytes about twice as fast and pays about six
times as much per message. Those lines meet at about 31 KiB, which is
past every point they were fitted to, so the break even was measured
rather than left as an extrapolation:

| message | pure Ruby | C extension | ratio |
| --- | --- | --- | --- |
| 16 KiB | 14.5 us/msg | 23.4 us/msg | 1.61 |
| 32 KiB | 27.4 us/msg | 29.3 us/msg | 1.07 |
| 64 KiB | 54.1 us/msg | 46.7 us/msg | 0.86 |

Break even is near 39 KiB, a little later than the fit said. Below it
this implementation is ahead, and by 64 KiB it is behind. So quote a
streaming ratio only with the message size attached: it is 6.1 at 64
bytes, 1.6 at 16 KiB, gone by about 39 KiB, and reversed by 64 KiB.

The per message difference is a completion semantics difference, and that
part rests on reading the code rather than on one timing: the C
extension's `SEND_MESSAGE` batch does not return until C-core has taken
the message, a round trip across the Ruby and C boundary for each one,
while this implementation copies the message into a queued frame and
returns, applying backpressure at a 256 KiB watermark instead. Timing
`Call#run_batch(SEND_MESSAGE)`, which both provide, agrees: a mean of 33
us against 3.9 us, and in both cases the mean send accounts for
essentially the whole per message cost measured end to end. Use the mean
and not the median here; the distribution is skewed by the messages that
do block, and an earlier note quoting a 30 us median against a throughput
average appeared to contradict itself for that reason.

So the honest claim is not that Ruby moves bytes faster than C. It is
that gRPC Ruby's C extension pays a per message round trip on the send
path and this does not. That dominates for small messages, is worn away
by the per byte cost as messages grow, and has gone by about 39 KiB.
Past that the C extension is ahead.

The one case still behind is a 64 KiB unary payload, at about three
quarters of the C extension.

Copying is not the main cost there, which is worth knowing before anyone
spends time on zero copy plumbing. An RPC takes about 330 us against
about 255 us, a gap of roughly 75 us, and one 64 KiB copy is about 8 us.
Two experiments:

- Removing one copy from the send path, by queueing the caller's payload
  rather than copying it into the frame, was worth 4.8 per cent over
  twelve paired runs. It was reverted anyway: it is not correct. See the
  note on `send_message`.
- Removing another, by holding received DATA as segments instead of
  appending it into one buffer, won 5 of 10 paired runs: no effect. Also
  reverted.

Holding the payload size fixed and turning four DATA frames into one, by
raising the frame size, was worth 7 per cent, so per frame work matters
more than copying. That change was reverted anyway, because it fails
h2spec 4.2.3.

A Vernier profile of a saturated run -- eight threads of 64 KiB calls --
puts 53 per cent of samples in `Thread::Queue#pop`, 30 per cent in
`ConditionVariable#wait`, 12 per cent in `IO#write` and `IO#readpartial`,
and under 1 per cent in all of this library's own Ruby frames put
together. Read that only as "there is no hot Ruby method here". Sample
shares over mostly idle threads say nothing about which part of a serial
round trip the 75 us sits in; idleness is not latency.

Timestamping the stages of a single sequential call does apportion it.
Handler work is 0 us and the two halves are roughly symmetric. The
largest single stage is about 75 us between two consecutive `readpartial`
calls on the receiving side, waiting for the rest of a 64 KiB payload to
arrive.

The obvious suspect after that is the write thread: `send_message` only
queues a frame, and something else has to put it on the socket. A light
probe splits that delay in two:

| | |
| --- | --- |
| queued -> write thread popped it | 8 us |
| popped -> bytes handed to the socket | 14 us |

So writing inline from the calling thread, which is the change that
suggests itself, could recover at most the 8 us, about 5 per cent of a
round trip once both directions are counted. It would cost serialising
the socket against the write thread, in the one part of this code that
currently passes h2spec 146 of 146 on ten runs. That trade was judged not
worth making, on those numbers rather than on taste. Note the figure
depends on how heavily the code is instrumented: a fuller probe, which
itself stretched the round trip from 330 us to 419 us, put the same delay
at 50 us.

Three attempts on this case were measured and dropped: holding received
DATA as segments (5 of 10 paired runs), waking a blocked reader only when
its byte count can be satisfied (8 of 20 paired runs, sign test p = 0.87),
and the inline write above (capped at about 5 per cent before it was
built).

This case is unresolved. Nothing here shows it is a floor; what it shows
is that the cheap moves are used up and the next ones cost real risk.

Loading the library takes about 110 to 145 ms, against about 10 to 25 ms
for the C extension.

A benchmark server holds about 150 MB resident against about 61 MB, so
roughly two and a half times. Part of that is the price of the settings
above: the 1 MiB connection window bounds how much unread data one
connection may hold, and each session keeps a 64 KiB read buffer and a
64 KiB write buffer. Lowering `ADVERTISED_INITIAL_WINDOW_SIZE` trades
throughput on large messages back for memory.

### Rules for the hot path

These are the things that were actually worth doing, measured. Keep them
in mind before changing `session.rb`, `rpc_stream.rb` or `hpack.rb`.

- Read frames through the single buffer in `FrameReader`. Decode integers
  in place with `getbyte` and `unpack1(offset:)`. Copy out only what has
  to outlive the buffer, which is a DATA payload or a header block.
- Build frames by appending bytes. `buf << byte` chained nine times
  measured about 1.8 times faster than
  `[len_type, flags, id].pack("NCN", buffer: buf)`, which allocates an
  Array per frame. `String#append_as_bytes` was slower still for this,
  and only earns its place where it saves a `String#b` copy of a whole
  payload.
- Never queue a caller's String for the transport to write later. Copy it.
  `send_message` returns while the frame is still queued, and a marshaller
  may hand out one reused buffer, so aliasing puts whatever the caller does
  next on the wire. Worse, the length prefix is fixed at send time while
  the bytes are not, so a payload that changes size desynchronises the
  stream and kills the RPC. The C extension copies into a byte buffer for
  the same reason.
- Append a caller's payload with `Body.append_bytes`, never `buf << str`.
  A payload arrives in whatever encoding the caller had, and appending a
  UTF-8 slice to the binary write buffer raises
  `Encoding::CompatibilityError` once that buffer holds a frame header
  with a high byte in it. A frame boundary can also split a codepoint, so
  the slice need not be valid text.
- Never let an accumulator grow past a Fixnum. The Huffman encoder shifted
  every bit of the string into one Integer and never masked it, so it
  became a Bignum after eight bytes and every shift after that allocated.
  Fixing that alone doubled the encoder.
- Measure before producing. HPACK asks `Huffman.encoded_bytesize` first
  and only encodes when the result would be shorter; measuring costs about
  40 per cent of an encode, and the literal often wins.
- Consume buffers with a cursor, never by reslicing the remainder.
- Do not do work per frame that can be done per window: acknowledging
  flow control in blocks is what took streaming from 23000 to over 300000
  messages a second.
- Measure with paired, interleaved runs. This benchmark drifts by several
  per cent between runs, enough to hide a real 4 per cent change and to
  invent one that is not there. Two changes tried here were reverted
  because paired runs showed no effect.

## Known gaps

- A 64 KiB unary payload runs at about three quarters of the C extension,
  and that is unresolved rather than understood to be a floor. The stage
  timings above point at the delay between queueing a frame and the write
  thread writing it. See the note above before trying anything else.
- There is no keepalive. `grpc.keepalive_time_ms` is accepted and
  ignored. A half-open connection is noticed when a read fails.
- There is no retry policy, no service config, no load balancing beyond
  one connection per channel, and no name resolution beyond DNS through
  the resolver of the host.
- XDS credentials fall back to their wrapped credentials. There is no
  xDS control plane client.
- `GRPC::Core::CompressionOptions` is honoured for channel arguments.
  A server does not compress a response unless the client asked for an
  algorithm.
- `load_grpc_with_gc_stress_test.rb` passes but takes about five minutes.
  It sets `GC.stress` before it loads the library, and loading Ruby code
  allocates far more than opening a shared object did.
