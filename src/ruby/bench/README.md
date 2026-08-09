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

| Pairing | Metric | No YJIT | YJIT | median |
| --- | --- | --- | --- | --- |
| `self/self` | unary qps | 4610-4866 | 7386-7620 | +58% |
| `self/baseline` | s-stream msg/s | 208505-212565 | 313603-318949 | +50% |
| `baseline/self` | s-stream msg/s | 53300-54277 | 53602-54397 | 0% |
| `baseline/baseline` | unary qps | 6068-7770 | 6599-6771 | +6% |

YJIT is worth 50 to 58 per cent wherever pure Ruby is doing the work, and
the ranges do not overlap. Two rows show nothing, for different reasons:

- `baseline/baseline` is the C extension on both sides, which does its
  work outside the Ruby VM. The ranges overlap, so this benchmark cannot
  separate its median change from run to run variation.
- `baseline/self` is pure Ruby receiving from a C sender, and it does not
  move at all. That figure is set by how fast the C extension sends, not
  by how fast this implementation can receive, so speeding up the Ruby
  side does not show up in it.

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
you care about. For example:

```
  server/client   s-stream m/s  c-stream m/s
  self/baseline         310231         49935
  baseline/self          54599        330655
```

`self` is the sender in `self/baseline` server streaming and in
`baseline/self` client streaming, and reaches about 310000 and 330000
messages a second. It is the receiver in the other two cells, at about
50000 and 55000.

Do not read that gap as the receive path being six times slower. Both of
those cells have the C extension on the other side, and 50000 to 55000
messages a second is close to what the C extension reaches sending to
itself. These two cells measure the C peer, not this implementation. The
`self/self` row is the one that shows what pure Ruby does at both ends.

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
