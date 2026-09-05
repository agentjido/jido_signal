# Signal v3: six follow-up optimization candidates

All six final changes were kept. Two trial forms were discarded after repeated measurements showed regressions. No dependency or public API contract changed.

The benchmark setup is commit `9196f70`. The final runtime code is commit `25aa702`. The control uses the same benchmark files with the runtime code from before these six changes.

## Round decisions

| Round | Change | Decision | Time A / B | Work ratio | Runtime commit |
| --- | --- | --- | ---: | ---: | --- |
| 1 | ASCII prefix scan | Keep | 0.386 / 0.379 | 0.429 | `ddc83e3` |
| 2 | No-subscriber delivery | Keep | 0.889 / 0.924 | 0.838 | `cdcd130` |
| 3 | Replay pattern preparation | Keep | 0.130 / 0.097 | 0.218 | `b1162b8` |
| 4 | Decoded term size check | Keep | 0.704 / 0.749 | 0.693 | `1e92b17` |
| 5 | Subscription removal | Keep | 0.019 / 0.017 | 0.020 | `0b61e14` |
| 6 | Log retention | Keep | 0.849 / 0.911 | 0.811 | `25aa702` |

Each row uses the representative case listed below. Ratios are after / before. Work is the Bus process reduction count for Bus cases and the caller reduction count for other cases. It comes from a separate activity pass.

### 1. ASCII prefix scan

Control: `baseline`. Candidate: `01-prefix`.

| Case | Before µs | After µs | Time A / B | Work ratio |
| --- | ---: | ---: | ---: | ---: |
| `candidate/utf8/ascii/json/candidates/32` | 7,594.083 | 2,905.000 | 0.386 / 0.379 | 0.429 |

### 2. No-subscriber delivery

Control: `01-prefix`. Candidate: `02-empty`.

| Case | Before µs | After µs | Time A / B | Work ratio |
| --- | ---: | ---: | ---: | ---: |
| `candidate/publish/empty/candidates/32` | 56,383.209 | 51,105.479 | 0.889 / 0.924 | 0.838 |

### 3. Replay pattern preparation

Control: `02-empty`. Candidate: `03-replay`.

| Case | Before µs | After µs | Time A / B | Work ratio |
| --- | ---: | ---: | ---: | ---: |
| `candidate/replay/exact/candidates/32` | 4,475.875 | 504.896 | 0.130 / 0.097 | 0.218 |

### 4. Decoded term size check

Control: `03-replay`. Candidate: `04-bound`.

| Case | Before µs | After µs | Time A / B | Work ratio |
| --- | ---: | ---: | ---: | ---: |
| `candidate/term/nested/candidates/32` | 548.250 | 397.854 | 0.704 / 0.749 | 0.693 |

### 5. Subscription removal

Control: `04-bound`. Candidate: `05-remove`.

| Case | Before µs | After µs | Time A / B | Work ratio |
| --- | ---: | ---: | ---: | ---: |
| `candidate/remove/durable/exact/candidates/32` | 2,321.396 | 41.937 | 0.019 / 0.017 | 0.020 |

### 6. Log retention

Control: `06-control`. Candidate: `06-repeat`.

| Case | Before µs | After µs | Time A / B | Work ratio |
| --- | ---: | ---: | ---: | ---: |
| `candidate/retention/empty/candidates/32` | 80.209 | 70.459 | 0.849 / 0.911 | 0.811 |

## Changes and discarded trials

1. The first UTF-8 trial used `String.valid?(data, :fast_ascii)` for the full value. It made the 1 MiB mixed-text map case about twice as slow. That form was discarded. The retained helper scans initial ASCII chunks, then checks the remaining UTF-8 data once. Unicode and invalid-byte tests cover both map and JSON boundaries.

2. The Bus skips only delivery routing when its subscription map is empty. It still validates, stores, and returns every record. Tests cover publication before a subscription, during a subscription, and after the last subscription is removed.

3. The store validates a replay path, prepares it once, and reuses it for each record. Literal patterns use binary equality. Wildcard patterns use the existing matcher with a prepared tuple. Tests cover exact paths, single wildcards, multiple globstars, zero-segment matches, cursor limits, and invalid patterns. The one-record cursor case has a small setup cost; the report below shows it.

4. The first Erlang trial always used `term_to_iovec/1` plus `iolist_size/1`. Large nested data became about 33% slower, so that form was discarded. The retained check first uses `external_size/1` as an upper bound. A fitting upper bound proves acceptance. Otherwise, the code calculates the exact canonical byte count before it returns a size error. Tests include legacy ETF encoding whose decoded canonical form is larger than its input, exact limits, binary data, invalid data, and compressed-term rejection.

5. The Router removes only the selected path and target. It preserves other entries and their registration values. Both ephemeral and durable removal use this operation. Tests remove the first, middle, and last shared route, add it again, remove the final route, and handle a target process exit.

6. With no durable subscriptions, retention removes the oldest tree entry directly. The durable retention path stays the same. The first pair had mixed time results. An alternating control/candidate/control/candidate sequence then showed a gain at both sizes. Tests cover pinned records, a rejected append, deletion of the last durable subscription, and a burst larger than the log capacity.

## Fresh final comparison

The control was rebuilt in a separate checkout. The candidate and short profiles each ran twice for both source states. The scale profile ran once for each state. Runs were serial, with no test or build command running at the same time. The tables show the mean of each pair of medians, plus both individual time ratios. These are local measurements, not timing guarantees.

| Case | Before µs | After µs | Time A / B | Work ratio |
| --- | ---: | ---: | ---: | ---: |
| `candidate/utf8/ascii/to_map/candidates/32` | 2,713.854 | 404.646 | 0.151 / 0.148 | 0.143 |
| `candidate/utf8/ascii/json/candidates/32` | 9,203.166 | 2,955.709 | 0.271 / 0.395 | 0.429 |
| `candidate/utf8/mixed/json/candidates/32` | 13,616.083 | 12,228.188 | 0.800 / 1.022 | 1.000 |
| `candidate/utf8/unicode/json/candidates/32` | 15,529.604 | 15,816.709 | 0.938 / 1.104 | 1.000 |
| `candidate/utf8/emoji/json/candidates/32` | 11,703.292 | 11,268.584 | 0.931 / 0.997 | 1.000 |
| `candidate/utf8/invalid_tail/from_map/candidates/32` | 3,315.479 | 417.396 | 0.108 / 0.150 | 0.144 |
| `candidate/publish/empty/candidates/32` | 56,787.645 | 51,927.062 | 0.917 / 0.912 | 0.838 |
| `candidate/publish/miss/candidates/32` | 58,444.729 | 60,441.792 | 1.039 / 1.029 | 1.000 |
| `candidate/publish/match/candidates/32` | 55,609.688 | 58,071.209 | 1.046 / 1.043 | 1.000 |
| `candidate/replay/exact/candidates/32` | 4,278.895 | 489.334 | 0.107 / 0.123 | 0.217 |
| `candidate/replay/single/candidates/32` | 5,129.020 | 3,080.708 | 0.551 / 0.660 | 0.750 |
| `candidate/replay/cursor/candidates/32` | 1.688 | 1.855 | 1.070 / 1.132 | 1.037 |
| `candidate/term/binary/candidates/32` | 3,476.500 | 441.562 | 0.109 / 0.153 | 0.141 |
| `candidate/term/nested/candidates/32` | 550.729 | 413.541 | 0.755 / 0.746 | 0.693 |
| `candidate/term/raw/candidates/32` | 84.291 | 38.730 | 0.399 / 0.552 | 0.082 |
| `candidate/remove/ephemeral/exact/candidates/32` | 2,333.416 | 43.855 | 0.016 / 0.021 | 0.014 |
| `candidate/remove/durable/shared/candidates/32` | 1,951.188 | 66.229 | 0.029 / 0.040 | 0.028 |
| `candidate/retention/empty/candidates/32` | 88.376 | 73.645 | 0.702 / 1.005 | 0.811 |
| `candidate/retention/many/candidates/32` | 6,510.500 | 6,846.354 | 0.987 / 1.125 | 1.016 |
| `candidate/retention/pinned/candidates/32` | 361.459 | 378.792 | 0.957 / 1.157 | 1.004 |

### Wider suite

| Case | Before µs | After µs | Time A / B | Work ratio |
| --- | ---: | ---: | ---: | ---: |
| `signal/new/small/8` | 18.500 | 18.188 | 0.942 / 1.028 | 1.000 |
| `signal/new_fixed/small/8` | 15.459 | 15.521 | 0.997 / 1.011 | 1.000 |
| `serialization/json/encode/large_binary/8` | 7,492.438 | 2,959.042 | 0.398 / 0.392 | 0.429 |
| `serialization/erlang_term/decode/large_map/8` | 142.979 | 121.584 | 0.897 / 0.807 | 0.962 |
| `router/exact/small/8` | 0.166 | 0.166 | 1.000 / 1.000 | 1.000 |
| `router/wildcard_many/extended/8` | 119.916 | 140.354 | 1.180 / 1.160 | 1.000 |
| `router/remove/extended/8` | 3.604 | 3.979 | 1.035 / 1.172 | 1.000 |
| `bus/subscribe_churn/small/8` | 107.251 | 115.520 | 1.074 / 1.081 | 1.014 |
| `bus/large_replay_filtered/extended/8` | 1,236.667 | 761.542 | 0.588 / 0.645 | 0.710 |
| `bus/concurrent_publish/extended/8` | 7,468.374 | 8,046.730 | 1.049 / 1.107 | 0.999 |
| `bus/sustained_publish/extended/8` | 15,417.729 | 14,056.625 | 0.899 / 0.925 | 0.832 |
| `bus/durable_ack/small/8` | 165.562 | 158.229 | 0.952 / 0.959 | 1.003 |

## Timing variation and memory trade-offs

The short final pair showed slower wildcard construction, rejection of oversized
input, and small subscription churn. A separate probe used five blocks of 101
samples after 20 warm-up calls. It ran control, final, final, then control.
Wildcard construction measured 992 / 863 µs in the controls and 864 / 874 µs in
the final code. Oversized-input rejection measured 1.959 / 1.875 µs in the
controls and 1.917 / 1.875 µs in the final code. Small subscription churn measured
150 / 111 µs in the controls and 113 / 113 µs in the final code. The larger
slowdowns did not recur in this check. Full raw samples remain in the reports.

The one-record replay cursor case adds about 0.2 µs. The scale run also measured
oversized-input decoding at 42 ns before and 83 ns after. Its reduction count
increased from 21 to 24. This is a small cost of the shared size-check helpers.
These results do not show an improvement in every case.

Three candidate cases had sampled process memory more than 25% higher in both
final runs:

| Case | Before sampled bytes | After sampled bytes | Memory after GC |
| --- | ---: | ---: | --- |
| 64 KiB binary term decode | 10,584 | 16,616 | Caller unchanged at 5,704 bytes |
| Remove one of 32 durable multi-wildcard subscriptions | 131,336 | 198,456 | Bus fell from 90,832 to 57,344 bytes |
| Remove one of 512 durable shared-path subscriptions | 1,064,392–1,294,152 | 1,895,016–1,895,112 | Bus unchanged at 638,632 bytes |

In the short profile, small and large-binary Erlang decode also had higher
sampled heaps. Some 64 KiB JSON cases used 5,704 bytes after GC, compared with
3,832 bytes in the control. These samples do not establish lower memory use.

A repeated-publication probe ran 40 rounds on the same Bus, with 512 records per
round and a capacity of 128. Both versions retained 128 records and had a copied
state size of 125,672 bytes in every measured round after warm-up. After forced
GC, control Bus memory ranged from 88,600 to 230,456 bytes. Final Bus memory stayed
at 230,456 bytes. The final code used a larger allocated heap in this probe, with
no retained-state growth. Median time for the last 30 rounds was 15.26 / 15.41 ms
in the controls and 13.22 / 13.51 ms in the final code.

The supplemental probe source is saved as `regression_probe.source` in the raw
results directory. Its four JSON files record the source checksum and runtime.
It uses a separate method from the suite and does not replace the suite results.

## Measurement limits and validation

- Host: Apple M1 Max; Elixir 1.18.4; OTP 27.3; `ERL_FLAGS='+S 2:2'`; Mix dev environment.
- Candidate profile: 78 cases, 3 warm-up calls, 15 timed samples per case. Short profile: 114 cases with the same sample counts. Scale profile: 342 cases, 5 warm-up calls, 30 timed samples.
- Timing excludes setup, result checks, and cleanup. Memory and process activity use separate calls. The publication candidate runs eight batches on the same Bus.
- Observed process memory is a sampled value. It is not total allocation or an exact peak. The activity probe also reports memory after forced garbage collection. Minor-GC counts are net counters and can reset after a full collection.
- All 34 suite reports passed every result, process cleanup, copied-term, and fixture growth check. Fixture heap sizes match between compared runs.
- `mix test --include flaky --cover --warnings-as-errors`: 363 tests, zero failures; 96.5% coverage.
- `mix quality`, the explicit benchmark Credo check, the dependency lock check, and the dependency audit passed.

Raw reports, per-round analyses, and discarded patches are in the ignored directory `bench/results/optimization-six/`. The benchmark guide describes the profiles and measurement limits.

Reproduce a run with:

```sh
ERL_FLAGS='+S 2:2' mix run bench/run.exs --profile candidates --output bench/results/candidates
ERL_FLAGS='+S 2:2' mix run bench/run.exs --profile short --output bench/results/short
ERL_FLAGS='+S 2:2' mix run bench/run.exs --profile scale --output bench/results/scale
mix run bench/compare.exs BEFORE/report.json AFTER/report.json comparison.md
```
