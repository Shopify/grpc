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

## Verification

| Suite | How to run | State |
| --- | --- | --- |
| RSpec | `rspec -I src/ruby/lib -I src/ruby/spec -I src/ruby/pb src/ruby/spec` | 445 examples, 6 failures |
| End to end | run each `src/ruby/end2end/*_test.rb` | 23 of 24 |
| gRPC interop | `src/ruby/pb/test/{server,client}.rb` | 14 of 14, insecure and TLS |
| h2spec | point it at a server on the vendored session | 146 of 146 |
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

Use `src/ruby/bench`. See its README for the method. On one arm64 macOS
machine, against the precompiled grpc 1.83.0 gem, under YJIT:

| server/client | unary qps | p50 ms | large MiB/s | conc qps | s-stream msg/s | c-stream msg/s |
| --- | --- | --- | --- | --- | --- | --- |
| pure/pure | 4494 | 0.209 | 189.6 | 6076 | 23223 | 23305 |
| C/C | 8457 | 0.111 | 491.2 | 13712 | 56479 | 50816 |

The mixed rows separate the two directions. The pure Ruby send path
reaches about 210000 to 234000 messages per second, and the receive path
about 18000 to 21000. The receive path is therefore the limit, in both
directions, and it is the first thing to work on. Every DATA frame costs
a buffer append, a condition variable broadcast, and two `WINDOW_UPDATE`
frames.

Loading the library takes about 150 ms, against about 28 ms for the C
extension, and a server holds roughly 1.8 times the resident memory.

## Known gaps

- The receive path is slow, as above.
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
