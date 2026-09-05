# Signal Benchmarks

Run from the package root in a source checkout. Use Elixir 1.18 or later and
the dependencies in `mix.lock`:

```bash
ERL_FLAGS='+S 2:2' mix run bench/run.exs --output bench/results/before
```

The suite follows the report workflow used by Jido Action v3. Each run writes
`report.json` and `report.md`. Git ignores files under `bench/results/`.
The benchmark scripts and results are excluded from the Hex package.
No additional dependency is required.

| Profile | Cases | Sizes | Warm-up calls | Timing samples per case |
| --- | ---: | --- | ---: | ---: |
| `short` (default) | 114 | 8 | 3 | 15 |
| `scale` | 342 | 2, 8, 32 | 5 | 30 |
| `smoke` | 132 | 2, 6 | 1 | 2 |

Select a profile with `--profile scale` or `--profile smoke`. Short and scale
use a small map, a 1,000-entry map, and a 1 MiB ASCII binary for the original
cases. Smoke uses the small map for those cases. Extended cases use the
specific inputs listed below. Each case also takes one separate resource
sample. Profiles use sizes 2–32.

## Cases and timing boundaries

There are 66 operation types. The original 24 run for each size and payload.
The 42 extended operations run once per size with their own inputs. Case IDs
include the operation, payload or `extended` group, and size. Each JSON row
also records dimensions such as route count, batch size, or consumer count.
Each result is checked before the sample is accepted.

| Cases | Timed operation | Meaning of size |
| --- | --- | --- |
| `signal/new`, `new_fixed` | Construct and validate a Signal with a generated or supplied ID. | One Signal; repeated at each size. |
| `signal/to_map`, `from_map` | Convert to or from the canonical CloudEvents map. | One Signal. |
| `serialization/json/*`, `erlang_term/*` | Encode or decode one Signal. Encode results are decoded and checked after timing. | One Signal. |
| `router/build` | Build the route index. | `16 × size` exact routes and five overlapping routes. |
| `router/exact`, `wildcard`, `miss` | Look up a Signal in a prepared Router. | `16 × size` exact routes; wildcard and miss cases add five overlapping routes. |
| `router/predicate` | Evaluate matching predicates and return the accepted targets in order. | `16 × size` predicates; half accept the Signal. |
| `dispatch/noop`, `pid_async`, `pid_sync` | Dispatch through the public validation and delivery boundary. | One target. |
| `dispatch/fanout` | Send a Signal to separate receiver processes. | Number of receivers. |
| `bus/publish` | Publish a batch into an empty memory Store. | Number of Signals. |
| `bus/fanout` | Publish one Signal to separate subscriptions in the caller mailbox. | Number of subscriptions. |
| `bus/replay`, `replay_filtered` | Read the complete log, or scan it for the last matching record with a limit of one. | Number of retained records. |
| `bus/durable_ack` | Receive and acknowledge a complete batch, one record at a time. | Number of records. |
| `bus/retention` | Publish into a full log and remove the old records. | Log capacity and batch size. |
| `bus/subscribe_churn` | Create and remove subscriptions in sequence. | Number of subscription pairs. |

Router checks cover exact and wildcard precedence, specificity, priority,
registration order, predicate filtering, and missing routes. Bus checks cover
Signal values, cursor order, complete fanout, durable delivery, log retention,
and removal of subscriptions.

The extended operations cover the following cases:

| Cases | Timed operation and input |
| --- | --- |
| `signal/typed`, `typed_invalid`, `invalid` | Construct a typed Signal with nested Zoi validation, reject invalid typed data, or reject an invalid envelope. The typed list contains `size` items. |
| `trace/put`, `get`, `parse`, `format`, `child`; `context/put` | Set and read trace context, parse and format W3C traceparent, create a child span, or add a context attribute. |
| `serialization/base64/encode`, `decode` | Encode and decode invalid UTF-8 bytes through `data_base64`. Input is `size × 32 KiB`: 64 KiB to 1 MiB. |
| `serialization/nested/encode`, `decode` | Encode and decode nested JSON data with up to 16 levels. |
| `serialization/batch/json/*`, `batch/erlang_term/*` | Encode or decode `size` distinct small Signals. Checks preserve the complete batch and its order. |
| `serialization/invalid_json`, `invalid_term`, `invalid_base64`, `oversized`, `oversized_decode` | Reject malformed data and enforce configured encode/decode byte limits. |
| `router/wildcard_build`, `wildcard_many` | Build or query 32–512 distinct wildcard paths. All paths match an 11-segment Signal. Check the complete target set. |
| `router/deep` | Match a `**` path at depths 4–18 with up to 512 unrelated wildcard branches. |
| `router/add`, `remove`, `merge` | Update or merge the populated wildcard index. Check target membership and exact-route precedence. |
| `dispatch/dead_pid`, `timeout` | Reject a confirmed dead PID or return a 2 ms timeout from a live receiver that does not reply. The timeout is part of the measured operation. |
| `bus/fanout_processes` | Publish `size` Signals to `size` separate consumer processes and wait for all consumers to receive them. |
| `bus/concurrent_publish` | Release up to eight ready publishers. Each publishes four batches of `size` Signals. Two consumers receive all records. Check global cursor order and each publisher's order. |
| `bus/sustained_publish` | Publish 64 batches of `size` Signals through one full log with capacity `16 × size`. Check final retention after repeated eviction. |
| `bus/backlog_publish`, `backlog_drain` | Queue `16 × size` Signals for a paused consumer, or release the consumer to drain that queue. Explicit messages control the pause. |
| `bus/large_replay`, `large_replay_filtered`, `large_replay_cursor` | Replay 512–8,192 retained records, scan for the final match, or read the final page by cursor. Log setup is outside timing. |
| `bus/durable_reconnect` | Attach after the old consumer stops with an unacknowledged record. Receive and acknowledge that record again, then drain retained and offline records. Setup stops the old consumer outside timing. |
| `bus/invalid_signal`, `store_full`, `store_failure` | Reject an invalid Signal, a full Store pinned by a durable cursor, or an adapter append failure. Check that retained state is unchanged and no new Signal is delivered. |

Concurrent cases make each worker announce readiness before the timed release.
No assertion depends on publisher completion order. Consumer checkpoints come
from the same Bus as the data and confirm that no extra delivery occurred.
These checkpoints and final comparisons are outside timing. The reconnect
case includes guards against multiple outstanding durable records in its
receive/acknowledgement loop.

## Measurement method

Timing uses an untraced monotonic clock. Setup, result checks, receiver drains,
and cleanup are outside the timed interval. Each stateful sample starts fresh
Bus or receiver processes. Replay, retention, and acknowledgement setup fills
the Bus before timing starts. Durable acknowledgement timing includes receipt
of each record and its acknowledgement call.

Async PID timing ends when Dispatch returns. A synchronous drain then confirms
receipt at each receiver. The Bus reply is a delivery barrier for its caller
mailbox. The original `bus/fanout` case measures one mailbox. Extended fanout
and concurrent publication measure independent consumer processes. Backlog
publication holds its consumer queue until the resource observation is complete.

Resource samples run separately. Spawn tracing follows the measured caller
and its descendants. Barriers at setup and after the operation let the
observer inspect live processes and results. Monitors confirm process cleanup.
A failed resource probe stops its observed descendants before it returns.

| Metric | Meaning |
| --- | --- |
| Wall time | Raw nanosecond samples, minimum, median, p95, maximum, and mean. |
| Caller reductions | BEAM work in the caller; excludes Bus and receiver reductions. |
| Observed process memory and heap | Sum across the caller and its observed descendants at each barrier. |
| Shared binary bytes | Unique observed off-heap binary references. References can be shared with other processes. |
| Queued messages | Sum of caller and helper mailbox lengths at each observation barrier. |
| VM memory | Whole-VM use, including measurement tools and unrelated work. |
| Local and flat term heap | Fixture heap with and without local sharing; excludes off-heap binary payloads. |
| Copied heap and receiver memory | Measured after a real process transfer. Transfers reject flat heaps above 64 MiB. |
| External bytes | External Erlang term size; not message-copy cost. |

Retained terms are fixture inputs, not complete live Bus states. ETS and the
application Registry are outside the process memory totals. Observed maxima
can miss short allocations. Exact memory peaks and total helper reductions
are unavailable and appear as `null`.

Reports record the commit, source state, benchmark hash, lockfile hash,
configuration hash, runtime, machine, scheduler settings, samples, and
measurement limits.
The scripts use public Signal APIs. Term-size probes use BEAM inspection
functions and are diagnostic measurements.

## Compare runs

Use the same idle host, runtime, scheduler count, profile, and benchmark files.
Use separate checkouts and builds to compare code revisions. Run the same
benchmark scripts by absolute path from each package checkout.

```bash
ERL_FLAGS='+S 2:2' mix run bench/run.exs --output bench/results/after
ERL_FLAGS='+S 2:2' mix run bench/compare.exs \
  bench/results/before/report.json bench/results/after/report.json \
  bench/results/comparison.md
```

Reports use schema version 2. Use a new baseline directory for this expanded
suite; its case set and benchmark hash differ from the first suite.

The comparison requires matching suite, schema, environment, settings,
measurement method, benchmark hash, and case IDs. It rejects duplicate IDs.
Each ratio is the candidate value divided by the baseline value. A value
below one indicates a decrease. A zero baseline produces `unavailable`.

To enforce optional regression limits on the same host, add comparison budgets:

```bash
ERL_FLAGS='+S 2:2' mix run bench/compare.exs \
  bench/results/before/report.json bench/results/after/report.json \
  bench/results/comparison.md --max-time-ratio 1.25 --max-memory-ratio 1.30
```

These example limits allow at most a 25 percent median time increase and a
30 percent observed process memory increase in any case. The command writes
the comparison, then exits with an error if a limit is exceeded. A selected
budget also rejects zero baselines. Use repeated runs to choose limits that
suit the host. Timeout cases include the configured wait and scheduler noise.

Repeat measurements before you make a performance claim. The suite measures
local operations with the memory Store and an adapter that rejects writes.
Network adapters, external storage, VM restart recovery, and a complete
failure matrix remain outside its scope. No benchmark telemetry handlers are attached.

Every profile checks heap growth for wildcard Routers and event batches at
sizes 2 and 32. A 16-fold input increase must stay within 32-fold flat heap
growth. Actual transferred heaps must match the flat size, and each transfer
must remain under 64 MiB. These portable checks run in CI with the smoke
profile. CI also tests the comparison budget rules. It has no fixed host
timing threshold. Exact memory peaks and total helper reductions remain
unavailable; comparison budgets use the observed process memory value.

Run the measurement tests directly with:

```bash
mix test test/bench/signal_bench_test.exs test/bench/extended_bench_test.exs
```

## Candidate profile

Use `ERL_FLAGS='+S 2:2' mix run bench/run.exs --profile candidates --output bench/results/candidates`
for the six follow-up optimization areas. The 78 cases use two sizes. They cover
ASCII, mixed Unicode, non-ASCII text, emoji, invalid UTF-8 tails, Erlang term
decoding, publication with zero or one subscriber, filtered store replay,
subscription removal from 32 and 512 subscriptions, and log retention with zero,
one, or 32 durable subscriptions. Retention includes pinned records and a full
store that must reject the append.

Each report also has an `activity` object. This separate call measures caller
reductions and, when the fixture has a Bus, Bus process reductions. It records
the net minor-GC counter and process memory after forced garbage collection.
A full collection can reset the minor-GC counter. These values do not measure
total allocation or an exact memory peak. The publication cases run eight
batches on the same Bus. Timing remains free of tracing and memory probes.
