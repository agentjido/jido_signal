# Signal v3: 10 optimization rounds

Run date: 2026-09-05. Six changes remain. Four candidates were discarded.

The benchmark suite was pushed first at `b52b0e7`. The final runtime revision is `0f281ed`. The suite code, dependencies, runtime configuration, and scheduler count stayed fixed during all rounds.

The host used an Apple M1 Max, Elixir 1.18.4, Erlang/OTP 27.3, and `ERL_FLAGS='+S 2:2'`. Measurements used a shared local host.

Each round ran the complete short profile twice: 114 cases, 3 warmups, and 15 timed samples per case. Each invocation checked its result. Memory and process cleanup were checked separately. The next round used the last retained source as its control. Report prefixes below identify the raw data under the ignored `bench/results/optimization/` directory.

The table gives two time ratios for one relevant case in each round. Each ratio divides the candidate median by the control median. Values below 1.0 mean less time. Reductions measure caller work; they exclude Bus server work.

| Round | Change | Final decision | Measured case | Time A / B | Reductions ratio | Control report |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Generate an ID only when it is absent | Keep | `signal/new_fixed/small/8` | 0.872 / 0.872 | 0.982 | `00-before` |
| 2 | Build the parsed Signal struct directly | Discard after memory check | `signal/from_map/large_map/8` | 0.874 / 0.912 | 0.979 | `01-candidate` |
| 3 | Use Map.reject for absent wire attributes | Discard after memory check | `signal/to_map/small/8` | 0.920 / 0.917 | 0.817 | `02-candidate` |
| 4 | Return empty extension maps early | Discard | `signal/typed/extended/8` | 1.070 / 1.100 | 0.991 | `03-candidate` |
| 5 | Scan adjacent wildcards without list chunks | Keep | `router/wildcard_build/extended/8` | 0.962 / 0.518 | 0.845 | `03-candidate` |
| 6 | Calculate route specificity in one pass | Keep | `router/wildcard_build/extended/8` | 0.950 / 0.921 | 0.875 | `05-candidate` |
| 7 | Skip path splitting for exact-only indexes | Keep | `router/exact/small/8` | 0.443 / 0.443 | 0.821 | `06-candidate` |
| 8 | Validate replay patterns once per read | Keep | `bus/large_replay_filtered/extended/8` | 0.306 / 0.276 | 1.000 | `07-candidate` |
| 9 | Check record cursors without temporary lists | Discard | `bus/publish/small/8` | 1.100 / 1.053 | 1.000 | `08-candidate` |
| 10 | Normalize construction attributes once | Keep | `signal/new_fixed/small/8` | 0.901 / 0.953 | 0.948 | `08-candidate` |

Candidate report prefixes are `01-candidate` through `10-candidate`. Each has `-a` and `-b` directories. Candidate patches and the complete JSON and Markdown reports remain local.

The retained change commits are `2473233`, `ca71175`, `9e1ad0f`, `d21a47a`, `b972e1b`, and `b024852`. Commit `0f281ed` removes the two candidates rejected after the memory check.

Round 4 did not improve repeated timing. Round 9 also failed to improve publication timing. Both changes were removed before the next round.

Rounds 2 and 3 first passed the time check. The final memory check changed those decisions. Round 2 raised sampled process memory for small JSON decoding from 13,600 to 18,488 bytes in both runs. Round 3 raised it for small map output from 3,832 to 6,840 bytes in both runs. These changes were removed in `0f281ed`. Their time gains did not justify those increases.

Round 5 had a noisy control run for wildcard construction. Its two time ratios differ greatly. The repeatable reduction in caller work supports the change; the final comparison below is the better estimate of its combined effect with round 6.

The final short comparison reran the original `b52b0e7` source in a separate checkout and compared it with the six retained changes. The control used a dependency symlink, so its checkout flag is dirty; its runtime-source flag is clean. Final prefixes are `final-control-a`, `final-control-b`, `final-after-a`, and `final-after-b`.

The values below average the two run medians. They show selected operations and two controls. Small time changes can be noise; there is no claim that every operation is faster.

| Case | Before median | After median | Time ratio | Reductions ratio |
| --- | ---: | ---: | ---: | ---: |
| `signal/new_fixed/small/8` | 20.146 µs | 15.521 µs | 0.770 | 0.934 |
| `signal/new/small/8` | 19.188 µs | 19.105 µs | 0.996 | 0.953 |
| `signal/typed/extended/8` | 18.104 µs | 16.791 µs | 0.928 | 0.959 |
| `signal/to_map/small/8` | 1.062 µs | 1.062 µs | 1.000 | 1.000 |
| `router/exact/small/8` | 0.375 µs | 0.188 µs | 0.500 | 0.821 |
| `router/build/small/8` | 657.625 µs | 661.396 µs | 1.006 | 0.867 |
| `router/wildcard_build/extended/8` | 970.583 µs | 847.250 µs | 0.873 | 0.739 |
| `bus/large_replay_filtered/extended/8` | 4,692.562 µs | 1,206.667 µs | 0.257 | 1.000 |
| `bus/concurrent_publish/extended/8` | 7,807.438 µs | 7,506.542 µs | 0.961 | 0.997 |
| `bus/sustained_publish/extended/8` | 17,549.938 µs | 15,347.854 µs | 0.875 | 1.000 |
| `serialization/json/encode/large_binary/8` | 7,570.126 µs | 7,734.645 µs | 1.022 | 1.000 |

No case was more than 25% slower in both final short runs. Sampled memory still has tradeoffs. These cases had more than 25% higher process memory in both separate resource samples:

| Case | Before sampled process memory | After sampled process memory |
| --- | ---: | ---: |
| `signal/new/small/8` | 8,712 bytes | 11,728 bytes |
| `bus/durable_ack/large_binary/8` | 97,520 bytes | 143,980 bytes |
| `bus/fanout_processes/extended/8` | 110,376 bytes | 139,040 bytes |
| `bus/store_full/extended/8` | 93,672 bytes | 119,256 bytes |

These values are observed process-memory samples, not exact peaks or total allocations. Shared binary memory is measured separately. The durable-ack case also retains about 1 MiB of shared binary data. Retained fixture heap sizes are unchanged for all 114 cases, and copied heap sizes match the flat heap estimates. The six retained changes give clear gains in supplied-ID construction, exact lookup, wildcard construction, and filtered replay, with these remaining sampled-memory costs.

The final scale profile passed all 342 cases at sizes 2, 8, and 32. It checked result correctness, resource cleanup, and fixture growth. Its one-run comparison with the earlier scale baseline is supplementary; use the repeated short comparison for timing decisions.

All 30 reports from this work have matching suite and environment metadata. All process cleanup and copied-heap checks passed. Full comparison files are `comparison-a.md`, `comparison-b.md`, and `comparison-scale.md` under the local results directory.

Validation: 354 tests passed with flaky tests included; configured package coverage is 96.5%. `mix quality` passed formatting, compilation, Doctor, ExDoc, Credo, and Dialyzer. The dependency lock and Hex audit checks passed. Added tests cover adjacent multi-wildcards, replay filtering before limits, invalid replay patterns, constructor key collisions, explicit nulls, and mixed legacy/binary attributes.

Reproduce the profile runs and comparisons from the package root:

```sh
ERL_FLAGS='+S 2:2' mix run bench/run.exs --output bench/results/short
ERL_FLAGS='+S 2:2' mix run bench/run.exs --profile scale --output bench/results/scale
mix run bench/compare.exs BEFORE/report.json AFTER/report.json bench/results/comparison.md
```

Use the same host, runtime, configuration, scheduler count, dependencies, and suite revision for before/after runs. Run each revision at least twice. Run tests and builds outside benchmark measurement.

Suite SHA-256: `a7fd5a57ee7c1d30539c82df2f1eeae5f54e875540f0986c8133700b9ee410b9`.

Dependency lock SHA-256: `5ba0665eca8dd990a80a67e7ceb284a1879e5f172f18b37b3a6c7bbb66679f9e`.
