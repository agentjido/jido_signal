# Jido Signal - Agent Guide

## Build/Test/Lint Commands
- `mix deps.get` - fetch dependencies
- `mix test` - run full test suite (excludes flaky tests)
- `mix test test/path/to/file_test.exs` - run single test file
- `mix test test/path/to/file_test.exs:42` - run single test at line 42
- `mix test --exclude flaky` bypassed by running plain `mix test` for debugging
- `mix q` or `mix quality` - format, compile with warnings-as-errors, dialyzer, credo
- `mix format` - format code, `mix compile --warnings-as-errors` - strict compilation
- `mix coveralls.html` - test coverage report

## Architecture
- OTP application with supervision tree: `Jido.Signal.Supervisor` → Registry + Task.Supervisor
- Main modules: `Jido.Signal` (struct), `Jido.Signal.Bus` (GenServer pub/sub), `Jido.Signal.Router` (trie-based routing)
- Dispatch adapters: `:pid`, `:pubsub`, `:http`, `:bus`, `:named`, `:console`, `:logger`, `:noop`
- In-memory persistence via ETS or maps, no external DB dependency
- Middleware pipeline for cross-cutting concerns
- **Instance isolation**: `Jido.Signal.Instance` for multi-tenant/isolated infrastructure via `jido:` option

## Router System
- **Trie-based routing**: Efficient prefix tree for path matching with O(k) complexity (k = segments)
- **Pattern matching**: Exact (`"user.created"`), single wildcard (`"user.*"`), multi-level (`"audit.**"`)
- **Handler ordering**: By complexity (exact > wildcard) → priority (-100 to 100) → registration FIFO
- **Performance optimizations**: Direct segment matching (no trie build per match), efficient wildcard traversal
- **Route definition formats**:
  - `{path, target}` - Simple route with default priority 0
  - `{path, target, priority}` - Route with priority (-100 to 100)
  - `{path, match_fn, target, priority}` - Route with pattern matching function
  - `{path, [targets]}` - Route with multiple dispatch targets
- **Dynamic management**: `Router.add/2`, `Router.remove/2`, `Router.has_route?/2`
- **Pattern utilities**: `Router.matches?/2`, `Router.filter/2` for signal filtering
- **Internal structure**: Router.Engine (trie ops), Router.Validator (path validation), Router.Route (definition)

## Code Style
- snake_case functions, PascalCase modules under `Jido.Signal.*`
- TypedStruct for struct definitions with enforced keys & types
- Extensive `@moduledoc`/`@doc` with parameters, returns, examples
- Error handling: `{:error, Jido.Signal.Error.t()}` or atoms
- `with...do` pipelines for public API functions
- Pattern matching guards, early validation with NimbleOptions
- Tests use ExUnit, Mimic for mocking, tags `:capture_log`, `:flaky`, `:skip`

## Git Commit Guidelines

Use **Conventional Commits** format for all commit messages:

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

**Types:**
- `feat` - New feature
- `fix` - Bug fix
- `docs` - Documentation only
- `style` - Formatting, no code change
- `refactor` - Code change that neither fixes a bug nor adds a feature
- `test` - Adding or updating tests
- `chore` - Maintenance tasks, dependency updates

**Examples:**
```
feat(router): add wildcard pattern matching
fix(bus): handle subscriber exit during dispatch
docs: update signal routing guide
test(dispatch): add circuit breaker tests
chore(deps): bump splode to 0.2.10
```
