# AGENTS.md - Jido.Signal Guide

## Intent
Model domain events as validated signals and route them predictably through bus/dispatch layers.

## Runtime Baseline
- Elixir `~> 1.18`
- OTP `27+` (release QA baseline)

## Commands
- `mix test` (default alias excludes `:flaky`)
- `mix test --include flaky` (full suite)
- `mix q` or `mix quality` (`format --check-formatted`, `compile --warnings-as-errors`, `credo`, `dialyzer`)
- `mix coveralls.html` (coverage report)
- `mix docs` (local docs)

## Architecture Snapshot
- `Jido.Signal`: CloudEvents-style signal envelope + constructor/validation API
- `Jido.Signal.Bus`: pub/sub bus with routing, middleware, and persistence hooks
- `Jido.Signal.Router`: trie-based matcher (exact, `*`, `**`) with priority ordering
- `Jido.Signal.Dispatch`: adapter layer (`:pid`, `:pubsub`, `:http`, `:bus`, `:logger`, etc.)
- `Jido.Signal.Instance`: isolated multi-tenant signal infrastructure via `jido:` option

## Standards
- Use clear dot-delimited signal types and validate boundaries aggressively
- Use **Zoi-first** schema contracts for new signal definitions
- Keep transport concerns in adapters/bus, not in signal model structs
- Keep error returns structured (`{:error, Jido.Signal.Error.t()}` or documented atoms)
- Prefer explicit routing and persistence behavior over implicit defaults

## Testing and QA
- Cover route matching precedence (exact vs wildcard) and priority ordering
- Cover subscriber lifecycle and persistence/checkpoint behavior explicitly
- Treat skipped tests as temporary: include reason + follow-up issue in test metadata/comments

## Release Hygiene
- Keep semver ranges stable (`~> 2.0` for Jido ecosystem peers)
- Use Conventional Commits
- Update `CHANGELOG.md` and docs for behavior/API changes

## References
- `README.md`
- `usage-rules.md`
- `guides/`
- https://hexdocs.pm/jido_signal
