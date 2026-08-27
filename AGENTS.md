# Jido Signal Repository Guide

## Scope

These instructions apply to the `jido_signal` package. The `release/v3` branch
contains the Jido Signal v3 beta. Treat Signal validation, routing, delivery,
serialization, and persistence boundaries as stable public contracts.

Keep unrelated user changes in the worktree. Do not restore v2 behavior or add
a compatibility layer unless the task requires it.

## Public package boundary

The package has five main public parts:

- `Jido.Signal` defines the CloudEvents-compatible Signal envelope.
- `Jido.Signal.Serialization` defines canonical map, JSON, and Erlang term
  formats.
- `Jido.Signal.Router` defines exact and wildcard Signal type routing.
- `Jido.Signal.Dispatch` defines ordered delivery through adapters.
- `Jido.Signal.Bus` defines local publication, replay, and durable
  subscriptions.

The application owns retry, rate limiting, dead-letter handling, workload
isolation, and durable storage implementations.

## Source map

- `lib/jido_signal.ex` contains Signal construction and validation.
- `lib/jido_signal/context.ex` and `lib/jido_signal/trace.ex` contain transport
  context values.
- `lib/jido_signal/serialization.ex` and `lib/jido_signal/codec.ex` contain the
  wire boundary.
- `lib/jido_signal/router.ex` and `lib/jido_signal/router/` contain routing.
- `lib/jido_signal/dispatch.ex` and `lib/jido_signal/dispatch/` contain delivery.
- `lib/jido_signal/bus.ex` and `lib/jido_signal/bus/` contain Bus behavior and
  storage boundaries.
- `test/support/` contains shared fixtures.

Internal modules support the public API. Do not expose an internal module only
to make a test easy.

## Required workflow

For a behavior change:

1. Run the nearest existing tests.
2. Add a focused regression test.
3. Make the smallest complete change.
4. Run the focused test again.
5. Run the full suite and applicable quality checks.

Use these commands from the package root:

```text
mix test path/to/test_file.exs
mix test
mix test --include flaky --warnings-as-errors
mix format --check-formatted
mix compile --warnings-as-errors
mix doctor --summary
mix docs --warnings-as-errors
mix credo --min-priority high
mix dialyzer
MIX_ENV=test mix test --cover --warnings-as-errors
mix deps.unlock --check-unused
mix hex.audit
```

`mix quality` runs formatting, compilation, Doctor, ExDoc, Credo, and Dialyzer.
The total coverage floor is 90 percent. Generated Dialyzer PLTs belong under
the ignored `priv/plts/` directory and must not be committed.

## Contract rules

- Validate package-owned boundaries with Zoi.
- Keep Signal type paths dot-delimited and deterministic.
- Preserve Router order: exact paths, `*`, `**`, specificity, priority, and
  registration order.
- Keep Dispatch ordered and synchronous.
- Keep Bus durable delivery stored-before-send and at least once.
- Preserve useful failure data in documented structured errors.
- Do not create atoms from runtime Signal data.
- Keep transport context flat and separate from domain data.

## Test rules

- Test public behavior and the local rule that implements it.
- Use explicit messages, monitors, and barriers for process synchronization.
- Do not use `Process.sleep/1` as test synchronization.
- Use unique process names and telemetry handler IDs.
- Clean up processes, monitors, handlers, and global state.
- Use `async: true` only for isolated tests.
- Give skipped or flaky tests a reason.

## Documentation and package metadata

- Keep `README.md`, `CONTRIBUTING.md`, guides, and `mix.exs` metadata aligned.
- Document public modules, functions, types, options, results, and errors.
- Mark internal modules and functions as internal.
- Keep the Hex package file list explicit.
- Do not add repository automation, generated files, benchmarks, or local
  caches to the Hex package.
- Do not modify `CHANGELOG.md`; release notes are generated from Git history.

## Git and release rules

- Create normal topic branches from `main`.
- Use `release/v3` for approved v3 release maintenance.
- Use Conventional Commits.
- Do not move or reuse a release tag.
- Releases use signed, annotated `v` tags and the manual GitHub `Release`
  workflow.
