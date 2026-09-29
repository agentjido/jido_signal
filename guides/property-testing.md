# Property and Fuzz Tests

The [public contract register](public-contracts.md) gives stable contract IDs.
The test support follows the design in `jido_action` commit
`5e348a296d6059998cc1edacd6e266d90c914d28`. StreamData generates inputs and
shrinks failures. The package already has this dependency.

Run each suite from this package:

```sh
mix test.property --warnings-as-errors
mix test.fuzz --warnings-as-errors
```

The default `mix test` excludes both suites. The aliases select one suite and
use seed 0. To use another seed, add `--seed 123`. To select one test file:

```sh
mix test test/property/routing_model_test.exs --only fuzz --seed 123 --warnings-as-errors
```

Each case has a short property test and a larger fuzz test. Both use the same
assertions, fixed examples, and saved inputs. Ordinary ExUnit tests keep the
`:property` and `:fuzz` tags separate. The ExUnitProperties `property` macro
would add `:property` to a fuzz test.

| Case | Property runs | Fuzz runs | Property / fuzz input bounds |
| --- | --- | --- | --- |
| envelope_wire | 40 | 500 | Text length 6 / 20; all data forms and context limits |
| wire_mutations | 40 | 500 | Text length 32 / 512; known-invalid wire changes |
| routing_model | 40 | 500 | 6 / 16 routes; 1–5 type segments |
| memory_histories | 40 | 500 | 12 / 40 commands; retained bound 1–5; batch size 0–3 |
| trace_ids | 40 | 1000 | Complete UUID7 timestamp/random fields and byte flags |
| bus_histories | 40 | 500 | 12 / 40 commands; publication batch size 0–3 |
| diagnostics | 40 | 500 | Nesting 8 / 30; text 0–4000 characters; width 0–80 |
| dispatch_sequences | 40 | 500 | 6 / 20 targets; returned errors and propagated faults |
| pid_lifecycles | 40 | 500 | Two receiver results and four timeout values |
| durable_store_faults | 40 | 500 | Five callback fault classes and four timestamp forms |
| bus_observations | 40 | 500 | Publication batch size 1–4 / 1–12 |

Generation stops at the run count or the time limit. Property generation has
10 seconds per case; fuzz generation has 300 seconds. Fixed examples and replay
run first and are outside that limit. Each failure has at most 200 shrink steps.
The ExUnit timeout is 90 seconds for a property and 900 seconds for a fuzz test.
Use the measured report counts; a time-limited test can generate fewer inputs.

## Expected results

The routing model is a recursive recognizer. It does not call the production
trie or compiled matcher. Route order uses the documented score as an independent
list sum. The Memory model uses ordinary lists and a required-record predicate.
The Bus model keeps an accepted-record log and explicit durable state. UUID7
expectations use independent byte assembly and complete byte comparison.

Wire assertions compare a separately built canonical map before conversion.
Invalid wire changes each have a known reason for rejection. Dispatch assertions
compare callback order, returned errors, propagated faults, and event pairs.
Bus telemetry assertions consume owned events in order and check scoped identity.
Diagnostic assertions check type/retry tables, redaction, and recursive bounds.

Each attempt creates and stops its own Bus, target processes, and Store Agent.
Monitors and explicit messages provide synchronization. Tests restore application
options and remove telemetry handlers in `after` blocks. A fixed compiled Router
module is reused and removed after each attempt. Inputs remain plain JSON;
process resources are created at test time.

## Saved failures

Each test checks fixed examples, then these files, before it generates inputs:

- `test/property/corpus/<case>/*.json`: package regression inputs.
- `_build/test/property-counterexamples/<case>/*.json`: local reduced failures.

A caught assertion, exception, throw, or exit from a generated attempt is
shrunk, saved atomically, and checked once more.
An unstable repeat still fails. A saved input failure stops the run before new
generation. Invalid replay files also fail before generation. Keep the input when
correcting an assertion or the implementation. Promote useful reduced inputs to
the package corpus. Do not save PIDs, references, functions, or other live resources.

## Reports

Each selected run replaces `_build/test/property-report.json`. An incomplete
report is written before test files load, so a load failure cannot retain an old
passed report. The final report includes the seed, runtime, package version,
StreamData version, Git revision and dirty flag, and a digest of source, tests,
configuration, lock file, and guides.

The report gives passed and missing contracts separately for each suite. Forced
case tags are declarations in passed tests. They are not measured execution
counts. Per-case records measure generated inputs, fixed examples, replay inputs,
shrink attempts, confirmations, elapsed time, and passing observations. Shrink
attempts and confirmations do not add observation evidence. Current records are
under `_build/test/property-fuzz/<run-id>/`.

Keep both the command exit status and its report. For a full selected suite,
check `status: finished`, `outcome: passed`, no artifact errors, no unknown contract
IDs, no invalid case IDs, and no missing contracts in that suite. A focused run
can pass and still have expected missing contracts. Copy a report before running
another suite if both results are needed. The support tests deliberately trigger
and catch failures; their failure banners are expected when those tests pass.

## Limits

These tests explore bounded inputs and sequential histories. Explicit messages
check selected process orders; they do not control all BEAM schedules. The suite
uses generation and shrinking, not a coverage-guided fuzz engine. Fixed tests
cover real HTTP requests, complete schema/compiler diagnostics, PubSub and Logger
integration, and further startup errors. No external durable database,
distributed delivery, retry policy, runtime matrix, or mutation score is claimed.
A passed property is evidence for its stated cases, not proof of the complete API.

The test process owns linked resources. An abrupt linked-process death, a forced
kill of the test process, an ExUnit timeout, or a VM failure can stop an attempt
before the helper can save an input or finish its measurements. ExUnit reports
process failures that it receives; the run may have missing measurements or an
incomplete report. Do not infer a passed case from a missing artifact. The
callback fault cases test faults returned or caught at the documented boundaries.
