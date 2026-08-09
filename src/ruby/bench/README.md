# gRPC Ruby benchmark

A self-contained throughput and latency benchmark for the Ruby
implementation. It runs a server and a client in separate processes and
prints a table.

This is not the cross-language performance suite. That suite lives in
`src/ruby/qps` and needs the C++ `qps_json_driver` binary. Use this
benchmark when you want a quick answer about the Ruby stack alone, or
when you want to compare two Ruby implementations against each other.

## Running it

Measure this checkout:

```sh
ruby src/ruby/bench/run.rb
```

Compare this checkout against another implementation. `--baseline` takes
the directory that holds its `grpc.rb`:

```sh
ruby src/ruby/bench/run.rb --baseline /path/to/other/grpc/src/ruby/lib
```

Add `--json` to get the raw measurements instead of the table.

To compare against the C extension, install a precompiled gem into a
directory of its own and point `--baseline` at it:

```sh
gem install grpc --version 1.83.0 --platform arm64-darwin \
  --no-document --install-dir /tmp/cgrpc
ruby src/ruby/bench/run.rb \
  --baseline /tmp/cgrpc/gems/grpc-1.83.0-arm64-darwin/src/ruby/lib
```

Choose the `--platform` value that matches your machine. The precompiled
gem must contain a build for your Ruby ABI version.

## YJIT

The benchmark runs under YJIT by default, because that is how the
implementations are meant to be compared. Opt out with `--no-yjit`:

```sh
ruby src/ruby/bench/run.rb --no-yjit
```

The flag reaches the benchmark processes as a command line option, so it
also overrides an inherited `RUBYOPT=--yjit`. The runner prints the state
that the processes reported, on the line above the table. Always record
it, because YJIT moves the two implementations by different amounts.

Five runs of each setting on one arm64 macOS machine gave these ranges:

| Pairing | Metric | No YJIT | YJIT |
| --- | --- | --- | --- |
| `self/self` | unary qps | 3210-3571 | 4455-4871 |
| `self/baseline` | s-stream msg/s | 177976-193630 | 221614-253849 |
| `baseline/self` | s-stream msg/s | 17302-18460 | 20160-22559 |
| `baseline/baseline` | unary qps | 4693-6254 | 6096-7210 |

The pure Ruby ranges do not overlap, so YJIT clearly helps it, by 17 to
34 percent depending on the path. The C extension ranges overlap, so this
benchmark cannot separate its 3 to 5 percent median change from run to
run variation. That is the expected shape: the C extension does its work
outside the Ruby VM.

## What it measures

| Scenario | What it shows |
| --- | --- |
| `unary_empty` | Round-trip cost with an empty payload. |
| `unary_large` | Bulk throughput. The payload moves in both directions. |
| `unary_concurrent` | How well one process shares the transport. |
| `server_stream` | The server sends many messages on one call. |
| `client_stream` | The client sends many messages on one call. |

Each scenario reports p50, p90, p99 and max latency in milliseconds. The
table shows p50 only; use `--json` for the rest.

The service marshals a String to itself, so protobuf stays out of the
measured path and the numbers describe the transport.

## Reading the comparison

With `--baseline` the runner measures all four pairings. Rows are named
`server/client`. gRPC is wire compatible between implementations, so the
two mixed rows isolate one implementation on one side of the wire.

Each streaming scenario has a sender and a receiver:

| Scenario | Sender | Receiver |
| --- | --- | --- |
| `server_stream` | the server column | the client column |
| `client_stream` | the client column | the server column |

To judge one implementation, read the two rows where it sits on the side
you care about. For example, these numbers say that `self` sends about
ten times faster than it receives:

```
  server/client   s-stream m/s  c-stream m/s
  self/baseline         187396         17598
  baseline/self          18808        199261
```

`self` is the sender in `self/baseline` server streaming and in
`baseline/self` client streaming, and both are fast. `self` is the
receiver in the other two cells, and both are slow. The receive path is
therefore the bottleneck, in both directions.

## Tuning

Every knob is an environment variable.

| Variable | Default | Meaning |
| --- | --- | --- |
| `GRPC_BENCH_UNARY_ITERS` | 2000 | Sequential empty unary calls. |
| `GRPC_BENCH_LARGE_ITERS` | 500 | Sequential large unary calls. |
| `GRPC_BENCH_LARGE_MESSAGE_BYTES` | 65536 | Size of the large payload. |
| `GRPC_BENCH_STREAM_ITERS` | 20 | Streaming calls per scenario. |
| `GRPC_BENCH_STREAM_MESSAGES` | 1000 | Messages in one streaming call. |
| `GRPC_BENCH_STREAM_MESSAGE_BYTES` | 1024 | Size of one streamed message. |
| `GRPC_BENCH_THREADS` | 8 | Threads in the concurrent scenario. |
| `GRPC_BENCH_THREAD_ITERS` | 400 | Calls per thread. |
| `GRPC_BENCH_POOL_SIZE` | 16 | Server handler threads. |

`server.rb` and `client.rb` also run on their own. Start the server, note
the port it prints, then point the client at it with `GRPC_BENCH_PORT`.
Both honour `GRPC_BENCH_LIB`, which selects the implementation to load.

## Caveats

- The client and the server share one machine, so the numbers include
  loopback and scheduler effects. Compare rows against each other, not
  against numbers from another machine.
- Resident set size comes from `ps`, so it is a rough figure.
