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
- **An idle subchannel is redialled only while a sibling is alive.**
  Nothing else redials one: `#await_connection` reconnects on a failed
  pick, and a pick keeps succeeding while any other address answers, so
  a backend that closed its own connection would otherwise be dropped
  for the life of the process. The guard is a live sibling and not an
  aggregate state, because a single-address channel going READY to IDLE
  aggregates to IDLE, and redialling there races the backoff path that
  owns "every address failed".
- **Public deadlines are absolute; internal clocks are monotonic.**
  `Channel#watch_connectivity_state` and every other API the C extension
  had take a `Time`, a `GRPC::Core::TimeConsts` value, or epoch seconds.
  `RpcStream.now` counts seconds from an arbitrary start such as boot, so
  passing `RpcStream.now + n` as a deadline names a moment decades ago:
  the call returns at once, and a loop around it spins and starves every
  other thread. Pass `Time.now + n`.
- **An RPC fails fast unless its method config sets `waitForReady`.**
  While the channel is in TRANSIENT_FAILURE, every pick fails at once with
  the connect error, as in C-core. An RPC whose method config has
  `waitForReady: true` waits until the channel connects or its deadline
  passes, and then gets DEADLINE_EXCEEDED; without a deadline it waits
  without limit. The service config is the only source of the setting:
  the Ruby API has no per-call `wait_for_ready` option.

## Verification

| Suite | How to run | State |
| --- | --- | --- |
| RSpec | `rspec -I src/ruby/lib -I src/ruby/spec -I src/ruby/pb src/ruby/spec` | 870 examples, 6 failures |
| End to end | run each `src/ruby/end2end/*_test.rb` | 23 of 24 |
| gRPC interop | `src/ruby/pb/test/{server,client}.rb` | 16 of 16, insecure and TLS |
| xDS conformance | `ruby src/ruby/pb/test/xds_conformance/run.rb` | 5 of 5 |
| PSM Light (upstream) | `src/ruby/pb/test/psm_light/run.sh`, see below | 4 of 4 |
| h2spec | point it at a server on the vendored session | 146 of 146, both write paths, 10 runs each |
| Negative HTTP/2 | `test/http2_test/http2_test_server.py`, see below | 8 of 8 |
| hpack-test-case | kantan's `test/test_hpack.rb` | 41 runs, 0 failures |
| RuboCop | `rake rubocop` | clean with RuboCop 1.86.2 |

Every result above was taken on Ruby 4.0.2, except PSM Light, whose Ruby
client runs on the `ruby:4.0-slim` image (4.0.7 on aarch64-linux at the
time). The gemspec's `~> 1.82.0` RuboCop (1.82.0 and 1.82.1 alike)
reports offenses that 1.86.2 does not, in files that were clean at the
time; use 1.86.2 when comparing against this table.

The six RSpec failures and the one end to end failure all shell out to
`cmake/build/grpc_ruby_plugin` and `cmake/build/third_party/protobuf/protoc`.
Those are C++ build artifacts. The tests compare generated `.rb` files
and never load the Ruby runtime. Build the plugin to run them.

The interop cases are every credential-free case in
`tools/run_tests/run_interop_tests.py`. Upstream runs 14 of them for Ruby
and lists both compression cases as server-unimplemented; the two are
implemented and run here, which is the only external test the deflate and
gzip paths have. The authentication cases need real credentials, so they
are not covered. Cross-language interop needs the Docker images that
`run_interop_tests.py` builds.

RSpec is the largest suite and the weakest signal: it was written beside
this code and can only catch a regression against this implementation's
own model, never a disagreement with gRPC. The suites that can are the
ones that run somebody else's client or server against this one, and two
of them had to be built or repaired to run at all.

`src/ruby/pb/test/xds_conformance/run.rb` drives the real
`pb/test/xds_client.rb` against an in-process fake control plane and real
backends. Upstream's driver, `tools/run_tests/run_xds_tests.py`, needs GCP
and Traffic Director, so no CI script anywhere references the Ruby xDS
client; before this harness it had never been run. It found the endpoint
push gap and, through it, the idle-subchannel redial bug.

`test/http2_test/http2_test_server.py` points adversarial servers at this
client, where h2spec points a client at this server. It is Python 2 era
and dead on modern Python; run a patched copy outside the tree rather
than modifying it, pinning `h2==3.2.0` and `protobuf==3.20.3`, and fixing
`dict.has_key`, the `client_side` keyword that moved into
`H2Configuration`, and a str buffer that must be bytes.

`src/ruby/pb/test/psm_light/` runs upstream's own xDS conformance suites,
unmodified: PSM Light, grpc/psm-interop's `tests/fallback_test.py` (gRFC
A71: three cases) and `tests/federation_test.py` (gRFC A47: one case).
They need no GKE, but upstream publishes their images only to a registry
that needs grpc-testing credentials, so `build_images.sh <psm-interop
checkout>` builds all four locally: psm-interop's Go control plane, this
repository's Python xDS interop server and client on released grpcio
wheels, and the Ruby client. Then
`PSM_INTEROP_DIR=<checkout> run.sh psm-local/ruby-client:latest
fallback_test`. The Python server stands in for upstream's canonical Java
one. Run the Python client first: it is the positive control, and it
passes 4 of 4 here too, so a Ruby failure is Ruby's. Two harness details
matter on a laptop. Logs, and the bootstrap every container mounts, live
under `$HOME`, because a VM-backed Docker may not share `/tmp`. When the
host's own name resolves to loopback, which the suites would put into
every EDS endpoint, `run.sh` substitutes the address containers use for
the host.

Getting these suites to pass found four defects that no spec had caught:
the test app counted an RPC when it was sent rather than when it
completed, so a client whose RPCs all failed late reported no failures;
the test app had no `--qps` default and slept forever after its first
RPC; a channel whose first resolve failed crashed its backoff timer and
stayed in TRANSIENT_FAILURE; and the xDS status thread spun, which
starved every other thread and made `xds_lrs_spec.rb` fail in a way that
looked like machine load.

## Performance

Use `src/ruby/bench`. See its README for the method. Medians of five runs
on one arm64 macOS machine, against the precompiled grpc 1.83.0 gem,
under YJIT:

| Scenario | pure Ruby | C extension | ratio |
| --- | --- | --- | --- |
| unary, empty payload | 7635 qps | 6610 qps | 1.16 |
| unary, 64 KiB payload | 3146 qps | 3806 qps | 0.83 |
| unary, 8 threads | 16586 qps | 15077 qps | 1.10 |
| server streaming | 352989 msg/s | 53483 msg/s | 6.60 |
| client streaming | 352659 msg/s | 52047 msg/s | 6.78 |

Those rows come from runs that measure all four server and client pairings
in a fixed order. Position within a run is worth a few per cent on this
machine, so read the table for scale and not for small differences. To
compare two trees, alternate them and take a sign test over the pairs.

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

The one case still behind is a 64 KiB unary payload, at about four fifths
of the C extension.

Three faults were found and fixed there. Together they are worth **8.4 per
cent** on that scenario and 7.3 per cent off its median latency, over 20
alternated pairs (20/20 on both, sign test p < 0.001). Every other scenario
is flat.

- **Nagle on accepted sockets.** The client end set `TCP_NODELAY`; the
  accepted end did not. A reply is a large DATA write followed by a small
  trailing HEADERS frame, and the caller cannot finish the RPC without
  that trailer, so the trailer waited on an acknowledgement of the data.
  Worth 6.3 per cent on its own, 18/20.
- **A receive buffer grown from empty.** A message of several frames was
  appended into a String that started with no room, so it reallocated and
  copied everything it already held each time. A CPU profile put that one
  line at 9.7 per cent of the whole implementation. `RpcStream#push_data`
  now sizes the buffer once when a chunk arrives that fills a whole frame.
  Worth about 3 per cent: +3.3 and +3.4 per cent over two sets of 24
  alternated pairs, 35 of those 48 pairs won.
- **The read buffer freed between reads.** `FrameReader#refill` emptied it
  before every `readpartial`, and `String#clear` frees the storage rather
  than keeping it: a 65577 byte String becomes 40 bytes. Every frame read
  therefore returned a 64 KiB buffer and took a new one. The clear is there
  so that a failed refill leaves nothing readable, which `readpartial`
  guarantees for end of file but **not** for a closed stream, so it now
  runs on the failure path only. Pooled over 48 pairs: 64 KiB unary 32/48
  (p=0.011) and 8 threads 34/48 (p=0.002), against client streaming 17/48
  (p=0.017, about -1 per cent).

The sizing is speculative, and deliberately does not read the length the
peer declared in the message prefix. Trusting that number would let five
bytes buy a large buffer on every stream at once. Instead the guess is made
from bytes already delivered: a chunk below one frame does nothing, and the
buffer is never made more than five times the chunk in hand, so what a peer
can make this side hold follows what it sent.

Fixing the first exposed a bug in status handling; see `Core::Call`
`#resolve_client_status` and `spec/status_precedence_spec.rb`. Once the
trailers and the peer's GOAWAY arrived in one segment, a finished RPC was
reported as UNAVAILABLE, because the status assembly read the trailers and
then discarded them in favour of the transport failure. A status the peer
sent is final; only a close with no status decides the outcome. That bug
also made `client_memory_usage_test` fail 4 runs in 40; it now passes 60.

Copying is not the main cost there, which is worth knowing before anyone
spends time on zero copy plumbing. After the two fixes above an RPC takes
about 319 us against about 253 us, a gap of roughly 66 us. A 64 KiB
userspace copy is about 1.4 us, so the gap is not copies. Measured on this
machine, a socket write costs 0.115 us/KiB at 64 KiB against 0.85 us/KiB
at 16 KiB: the syscall dominates, and a userspace copy is ten times
cheaper than either. Four experiments on copying:

- Removing one copy from the send path, by queueing the caller's payload
  rather than copying it into the frame, was worth 4.8 per cent over
  twelve paired runs. It was reverted anyway: it is not correct. See the
  note on `send_message`.
- Removing another, by holding received DATA as segments instead of
  appending it into one buffer, won 5 of 10 paired runs: no effect. Also
  reverted.
- Sizing that buffer from the length the peer declares measured +3.1 and
  +3.8 per cent, and was still not shipped: a peer can declare a length it
  never sends, so five bytes on each of many streams would reserve memory
  on all of them. What shipped uses delivered bytes instead and gets most
  of it. An earlier attempt at the same idea measured nothing at all,
  because its gate was five bytes too tight to ever fire. Check that a
  change is active before believing a null result.
- `IO#syswrite` beats `IO#write` by 31 per cent on a 65 KB write, 5.5 us
  against 7.3 us. That is about 1 per cent of an RPC and it brings partial
  write handling, so it was not taken.
- Carrying END_STREAM on the last message's own DATA frame, rather than an
  empty frame behind it, is worth 2.4 per cent on 64 KiB unary and was
  reverted anyway. It threads a keyword through five call levels down to
  the per message path, which a streaming client runs hundreds of thousands
  of times a second: client streaming lost 6.4 per cent and server
  streaming 3.0 per cent, both 19 of 24 pairs at p=0.003. One path gaining
  two does not pay for two paths losing six and three.

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
round trip the gap sits in; idleness is not latency.

A wall clock profile is the wrong lens for that reason. A **CPU** profile is
not: StackProf in `:cpu` mode samples whichever thread holds the GVL, so
idle transport threads cannot drown the picture. That profile found the
receive buffer growth above, at 9.7 per cent on one line, which a wall
profile had never shown. Its Ruby frames proved trustworthy; treat its
`IO#write` and `IO#readpartial` shares with suspicion, since a thread that
released the GVL to block in a syscall is not really running.

Do not measure CPU with both peers in one process. Doing so puts a pure
Ruby client and server on one GVL, which the real benchmark, with the
server in its own process, does not. In the two process shape neither
implementation is close to CPU bound:

| | wall | client CPU | cpu/wall |
| --- | --- | --- | --- |
| pure Ruby | 316 us | 141 us | 0.45 |
| C extension | 264 us | 126 us | 0.48 |

Both spend about half the round trip waiting, and this implementation burns
roughly 12 per cent more client CPU per call. So cutting CPU does not buy
wall time one for one; it only pays where the work sits on the critical
path, which is why the buffer fix landed and several smaller ones did not.

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

Attempts on this case that were measured and dropped: holding received DATA
as segments (5 of 10 paired runs), waking a blocked reader only when its
byte count can be satisfied (8 of 20 paired runs, sign test p = 0.87),
pooling receive buffers between streams instead of sizing them (7 of 20,
and slower than simply allocating one of the right size), carrying the
message length between streams as a size hint (target gain not significant
and server streaming down), building the send frame by growing its five
byte header rather than reserving the whole frame (22 per cent faster in a
microbenchmark, 7 of 24 pairs and client streaming down 6 per cent in the
real thing), the inline write above (capped at about 5 per cent before it
was built), and busy polling the socket before blocking.

One of those deserves its opposite. Keeping the *read* buffer's allocation
between reads pays, so the same was tried on the *write* buffer: replace
`wbuf.clear` after a flush with a fresh String of `WRITE_BUFFER_SIZE`. It
lost, and not narrowly -- 64 KiB unary 5 of 24, empty unary 5 of 24, eight
threads 3 of 24. The two buffers are not alike. `readpartial` fills toward
64 KiB every time, so holding that much room is always used; most write
flushes are a few hundred bytes of headers or an acknowledgement, so
reserving 64 KiB for each one is waste. `wbuf.clear` stays.

Busy polling is worth stating on its own, because it looks obvious. If the
gap were the kernel taking time to wake a blocked reader, spinning on
`read_nonblock` first would recover it. It does the opposite, and gets
worse the longer it spins: 3059 qps with no spin, 2887 at 20 us, 2839 at
100 us, and concurrent unary falls from 16548 to 11432. A spinning thread
holds the GVL against the thread that has to run next, so in Ruby this
trade is not available at any price.

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

### Measuring a change

Position in a benchmark run is worth a few per cent on this machine. A
patch measured always-first against a clean tree always-second showed, with
**identical code on both sides**, the first position losing 6 of 20 on
64 KiB unary (-1.6 per cent) and 5 of 20 on empty unary (-3.7 per cent).
That bias reversed the sign of two real results during this work.

So: alternate the order, ABBA, and take a sign test over the pairs. With
the order alternated the same null patch sits at 8 to 11 wins of 20 on
every metric. Twenty pairs resolve about 2 per cent. Anything smaller than
that is not measurable here, whatever a single pair of numbers says.

Microbenchmarks of allocation did not predict this system, in either
direction, and cost two wrong turns. Assembling a 64 KiB buffer from
16 KiB pieces measured 4.2 us in a loop and behaved like 20 us in the
library, because a loop reuses one hot block from the allocator while the
real thing keeps buffers alive and faults in new pages. The send frame
went the other way: growing it from its header measured 22 per cent faster
in a loop and lost 6 per cent of client streaming when shipped. Use a loop
to rank two lines of code, never to decide whether a change is worth
making. Only the paired A/B on the real workload decides that.

### Rules for the hot path

These are the things that were actually worth doing, measured. Keep them
in mind before changing `session.rb`, `rpc_stream.rb` or `hpack.rb`.

- Read frames through the single buffer in `FrameReader`. Decode integers
  in place with `getbyte` and `unpack1(offset:)`. Copy out only what has
  to outlive the buffer, which is a DATA payload or a header block.
- Know what `String#clear` does before putting it on a read or write path.
  It frees the storage: a 65577 byte String becomes 40 bytes, so the next
  append allocates again. On a path that refills to the same size every
  time, do not clear; hand the buffer straight to `IO#readpartial`, which
  overwrites it and keeps the allocation. On a path whose usual content is
  small, clear is the cheaper of the two. Both were measured; see above.
- Weigh a per message allocation by measuring its removal, not by counting
  it. Three removals from the streaming path, each isolated against the
  same tree, are worth very different amounts:

  | removed, per message | server streaming | client streaming |
  | --- | --- | --- |
  | one lambda (the write acknowledgement) | +5.2% (20/24) | +6.6% (21/24) |
  | one Array and its block (`OP_ORDER.select`) | +3.2% (23/24) | +2.5% (19/24) |
  | three Hashes (the `run_batch` ops) | +0.0% (12/24) | -0.4% (12/24) |

  Together the first two are worth 8.9 and 7.0 per cent. The three Hashes
  are free, so object count predicts none of this. What the two that pay
  have in common is a captured scope: `queue_write` built a lambda holding
  `size`, and `select` ran a block holding `ops`. Hash literals capture
  nothing. Prefer a receiver and a value, as `Body::Queue` now carries for
  acknowledgements, over a closure that has to hold them.
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
- Run a null patch first and read every result against it. Identical code
  on both sides measures **+7.3 per cent on `unary_empty`**, 9 pairs of 16:
  the A position is systematically favoured on that metric. A feature batch
  that read +12.7 per cent there was really worth about 5. On `unary_large`
  and `unary_concurrent` the floor is under 1 per cent at 7 or 8 pairs of
  16, so a result at 8/16 is nothing whatever the mean says. Trust the pair
  count over the mean: outliers move a mean and cannot move a count.
- Two regressions were found this way, neither visible in any spec. A
  `Mutex` taken on every RPC to read an already-memoised service config
  cost **12 per cent on the eight-thread benchmark**, fixed by reading the
  memo before taking the lock. Requiring the generated xDS protobufs from
  `transport.rb` cost **about 7 per cent on 64 KiB unary**, because 51000
  objects of Envoy message classes sat in the heap of every channel that
  never names an `xds:` target; loading them on demand put that metric back
  on the null floor. Neither shows up in a profile of the RPC path: one is
  lock contention, the other is GC pressure.
- The pair count is not stable either, below a few per cent. Two 16-pair
  runs of the same batch against the same base gave `unary_empty` at 9 of
  16 and then 2 of 16, and `unary_large` at 5 of 16 and then 3 of 16. When
  two runs of identical code disagree that far, the honest reading is that
  this harness cannot resolve an effect of that size, not that the second
  run found something. Raise the pair count or change the question; do not
  pick the run that agrees with you.
- BDP probing was implemented and measured and does nothing here. The
  growth ceiling is `max(RECEIVE_WINDOW, lookahead_bytes)` and
  `grpc.http2.lookahead_bytes` defaults to 64 KiB, well under the 1 MiB
  window this core already advertises, so a probe never arms unless a
  caller raises the argument past 1 MiB. It confirms rather than overturns
  the diagnosis below: the 64 KiB unary deficit is in the delay between
  queueing a frame and the write thread writing it, not in flow control.

## Known gaps

- A 64 KiB unary payload runs at about three quarters of the C extension,
  and that is unresolved rather than understood to be a floor. The stage
  timings above point at the delay between queueing a frame and the write
  thread writing it. See the note above before trying anything else.
- Configuration this implementation cannot act on is refused rather than
  ignored. A channel argument in the `grpc.` namespace that is not in
  `ChannelArgs::HONOURED` raises `ArgumentError`, and so does a target
  scheme outside `dns`, `ipv4`, `ipv6`, `unix` and `xds`. Names outside
  the `grpc.` namespace are still ignored, which is what the C extension
  did with them, and `channel_spec.rb` pins that.
- Retries cover unary, server-streaming and client-streaming calls. Bidi
  is deliberately not retried: requests and responses interleave on
  independent threads, so there is no point at which everything sent so
  far is both known and safe to replay. Hedging is unary only.
- The xDS client follows LDS, RDS, CDS and EDS over ADS, reports load
  back over LRS, and pushes endpoint changes into a live channel. It
  routes every resource by the authority in its own `xdstp://` name (gRFC
  A47), so a listener from one authority can name a cluster on another.
  It falls back through an authority's ordered server list when a watched
  resource is uncached and the active server fails, and it returns to a
  higher-priority server as soon as that server answers (gRFC A71). Each
  management server has one channel for as long as it is in use, so
  channelz shows a server that is down as TRANSIENT_FAILURE, which the
  PSM Light fallback suite checks. It does not implement SDS certificate
  provisioning, RBAC or fault-injection filters, aggregate clusters, or
  weighted locality routing beyond taking the heaviest cluster of a
  weighted set.
- Where the xDS client differs from C-core's: a subscription is never
  withdrawn, so an authority and its connections live as long as the
  process; reconnects are paced by the connection's backoff and by the
  channel's own, not one; the keepalive resend repeats only the listener
  subscription; a resource that names an authority the bootstrap does not
  define stays unresolved until its caller times out, not a distinct
  error; and a failing server whose resources are all cached produces no
  signal beyond channelz.
- A pushed endpoint list reaches a running channel; a DNS one does not.
  `dns:` targets still resolve once and re-resolve only after every
  address has failed, with no polling timer, which is what the C
  extension did. The machinery to change that is now in place:
  `Transport.watch_addresses` and `Channel#apply_resolver_push` take an
  address list from any source.
- The generated Envoy protobufs under `pb/xds` load on demand, the first
  time a target names the `xds` scheme. Do not require `xds_client.rb`
  from anything that loads eagerly; see the performance note above for
  what that cost.
- Load balancing offers `pick_first`, `round_robin`, `ring_hash` and
  `weighted_round_robin`, with outlier detection available as a wrapper
  over any of them and gRFC A17 health checking per subchannel. There is
  no grpclb, and no custom-policy registry for callers to add their own.
- The shipped health checker implements `Check` only. Client-side health
  checking drives the `Watch` RPC against a backend that offers it, and
  falls open when a backend does not, but this core's own servicer still
  has no `Watch`, which is what upstream Ruby ships. There is no server
  reflection. Channelz answers `GetTopChannels` and `GetChannel` with each
  channel's target and state; servers, subchannels, sockets and call
  counters are not tracked, and every other method is UNIMPLEMENTED. The
  C extension exposed neither to Ruby; channelz exists here because the
  PSM Light suites read ADS channel states through it.
- A leaked thread is a production bug here, not a test nuisance. Two were
  found by instrumenting `Thread.list` across the suite: `ClientStub` had
  no way to close a channel it opened for itself, where the C extension
  freed the channel from a GC callback, and every xDS stream reconnect
  left its write pump polling a queue nobody would ever push to. Anything
  that starts a thread needs an owner that joins it.
- `GRPC::Core::CompressionOptions` is honoured for channel arguments. A
  server does not compress a response unless the client asked for an
  algorithm, and a call may name the encoding of its own response, which
  is what the interop `response_compressed` flag asks for. There is no
  `stream/gzip`: it is absent from this repository's own algorithm enum,
  and upstream deleted the code behind it in 2021, so implementing it
  would be inventing a feature rather than matching one.
- `load_grpc_with_gc_stress_test.rb` passes but takes about five minutes.
  It sets `GC.stress` before it loads the library, and loading Ruby code
  allocates far more than opening a shared object did.
- A test written beside the code cannot find a disagreement with gRPC,
  only a regression against this model of it. Both production bugs found
  in the last round came from suites that run something external: the
  endpoint push gap and the idle redial bug from driving the real xDS
  client against a control plane, the compression gap from an interop
  case upstream had marked unimplemented. Prefer repairing a suite that
  talks to somebody else's code over adding another example to
  `src/ruby/spec`.
