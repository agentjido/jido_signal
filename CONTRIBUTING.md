# Contributing to Jido Signal

Thank you for contributing to Jido Signal. This guide describes the supported
development and review process.

## Supported environment

- Elixir `~> 1.18`
- Erlang/OTP 27 or later

The CI matrix also tests newer supported Elixir and OTP versions.

## Set up the project

1. Fork and clone the repository.
2. Install dependencies.
3. Run the default test suite.

```sh
git clone https://github.com/YOUR-NAME/jido_signal.git
cd jido_signal
mix deps.get
mix test
```

Create normal contribution branches from `main`. Use `release/v3` only when a
maintainer asks you to make a v3 release change.

## Source map

- `lib/jido_signal.ex` contains the Signal value and constructor API.
- `lib/jido_signal/context.ex` and `lib/jido_signal/trace.ex` contain transport
  context helpers.
- `lib/jido_signal/serialization.ex` contains the public serialization API.
- `lib/jido_signal/router.ex` contains the public routing API.
- `lib/jido_signal/dispatch.ex` contains the public delivery API.
- `lib/jido_signal/bus.ex` contains the public Bus API.
- `lib/jido_signal/bus/store.ex` defines the persistence boundary.
- `test/` follows the source layout and contains shared support in
  `test/support/`.

Internal modules support these public boundaries. Do not make an internal
module public only to simplify a test.

## Make a change

1. Keep the change focused on one subject.
2. Add or update tests for behavior changes.
3. Update public documentation for API, option, result, or error changes.
4. Run the nearest tests while you work.
5. Run the full checks before you open a pull request.

Use Zoi schemas for package-owned validation boundaries. Keep routing and
delivery deterministic. Return documented tagged tuples or structured Jido
Signal errors. Application policy such as retry, rate limiting, dead-letter
handling, and workload isolation does not belong in the Signal value.

## Required checks

Run the full quality suite:

```sh
mix quality
```

It runs formatting, compilation with warnings as errors, Doctor, ExDoc, Credo,
and Dialyzer.

Run tests and repository checks:

```sh
MIX_ENV=test mix test --cover --warnings-as-errors
mix test --include flaky --warnings-as-errors
mix deps.unlock --check-unused
mix hex.audit
```

The default `mix test` command excludes `:flaky` and `:skip` tests. The coverage
gate requires at least 90 percent total coverage.

## Test rules

- Test success and error paths through the public API.
- Use `async: true` only when the test and its fixtures are isolated.
- Use monitors and explicit messages for process synchronization.
- Do not use short sleeps as a substitute for a synchronization point.
- Give each temporary skipped or flaky test a reason.
- Clean up processes, telemetry handlers, and global state after each test.

## Documentation rules

- Add `@moduledoc` to public modules.
- Add `@doc` and `@spec` to public functions.
- Add `@typedoc` to public custom types.
- Use `@moduledoc false` or `@doc false` for internal surfaces.
- Add examples when they help a reader complete a task.

Check documentation directly with:

```sh
mix doctor --summary
mix docs --warnings-as-errors
```

## Commit and pull request rules

Use Conventional Commits:

```text
<type>[optional scope][optional !]: <description>
```

Common types are `feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `chore`,
`ci`, `build`, and `deps`.

Examples:

```text
feat(router): add route inspection
fix(bus): release a durable subscriber monitor
docs: clarify Signal context values
feat(api)!: remove a deprecated constructor
```

Pull requests must explain the change, include applicable tests and docs, and
pass CI. Do not edit `CHANGELOG.md`; release notes are generated from Git
history.

## Security reports

Do not open a public issue for a vulnerability. Use the repository's
[private security advisory form](https://github.com/agentjido/jido_signal/security/advisories/new).

## Releases

Maintainers publish releases through the manual GitHub `Release` workflow. A
release uses an existing signed, annotated version tag. Contributors do not
need to edit release files or publish packages.

For questions, open a
[GitHub Discussion](https://github.com/agentjido/jido_signal/discussions) or a
focused issue.
