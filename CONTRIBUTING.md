# Contributing to Jido Signal

Welcome to the Jido Signal contributor's guide! We're excited that you're interested in contributing to Jido Signal, the event signaling and pub/sub library for the Jido ecosystem.

## Getting Started

### Development Environment

1. **Elixir Version Requirements**
   - Jido Signal requires Elixir ~> 1.17
   - We recommend using asdf or similar version manager

2. **Initial Setup**
   ```bash
   # Clone the repository
   git clone https://github.com/agentjido/jido_signal.git
   cd jido_signal

   # Install dependencies
   mix deps.get

   # Install git hooks (enforces conventional commits)
   mix git_hooks.install

   # Run tests to verify your setup
   mix test
   ```

3. **Quality Checks**
   ```bash
   # Run the full quality check suite
   mix quality

   # Or individual checks
   mix format                    # Format code
   mix compile --warnings-as-errors  # Check compilation
   mix dialyzer                  # Type checking
   mix credo --strict            # Static analysis
   ```

## Code Organization

### Project Structure
```
.
├── lib/
│   ├── jido_signal/
│   │   ├── bus/           # Event bus implementations
│   │   ├── dispatch/      # Signal dispatching logic
│   │   ├── router/        # Signal routing
│   │   ├── journal/       # Signal journal + persistence adapters
│   │   ├── serialization/ # Signal serializers and schema helpers
│   │   └── ext/           # Signal extension helpers
│   └── jido_signal.ex     # Main entry point
├── test/
│   ├── jido_signal/
│   │   └── ...           # Tests mirroring lib structure
│   ├── support/          # Test helpers and shared fixtures
│   └── test_helper.exs
└── mix.exs
```

### Core Components
- **Bus**: Event bus for publish/subscribe patterns
- **Dispatch**: Signal dispatching and delivery
- **Router**: Signal routing based on topics and patterns
- **Dispatch Adapters**: Delivery targets like PID, PubSub, HTTP, and webhooks

## Development Guidelines

### Code Style

1. **Formatting**
   - Run `mix format` before committing
   - Follow standard Elixir style guide
   - Use `snake_case` for functions and variables
   - Use `PascalCase` for module names

2. **Documentation**
   - Add `@moduledoc` to every module
   - Document all public functions with `@doc`
   - Include examples when helpful
   - Use doctests for simple examples

3. **Type Specifications**
   ```elixir
   @type signal :: %JidoSignal{}

   @spec dispatch(signal()) :: {:ok, term()} | {:error, term()}
   def dispatch(signal) do
     # Implementation
   end
   ```

### Testing

1. **Test Organization**
   ```elixir
   defmodule JidoSignal.BusTest do
     use ExUnit.Case, async: true

     describe "publish/2" do
       test "publishes signal to subscribers" do
         # Test implementation
       end

       test "handles missing topic" do
         # Error case testing
       end
     end
   end
   ```

2. **Coverage Requirements**
   - Maintain high test coverage
   - Test both success and error paths
   - Include property-based tests for complex logic
   - Test async behavior where applicable

3. **Running Tests**
   ```bash
   # Run full test suite
   mix test

   # Run with coverage
   mix test --cover

   # Run specific test file
   mix test test/jido_signal/signal/bus_test.exs
   ```

### Error Handling

1. **Use With Patterns**
   ```elixir
   def subscribe(topic, opts) do
     with {:ok, validated} <- validate_topic(topic),
          {:ok, subscription} <- create_subscription(validated, opts) do
       {:ok, subscription}
     end
   end
   ```

2. **Return Values**
   - Use tagged tuples: `{:ok, result}` or `{:error, reason}`
   - Create specific error types for different failures
   - Avoid silent failures
   - Document error conditions

## Git Hooks and Conventional Commits

We use [`git_hooks`](https://hex.pm/packages/git_hooks) to enforce commit message conventions:

```bash
mix git_hooks.install
```

This installs a `commit-msg` hook that validates your commit messages follow the [Conventional Commits](https://www.conventionalcommits.org/) specification.

### Commit Message Format

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

### Types

| Type | Description |
|------|-------------|
| `feat` | A new feature |
| `fix` | A bug fix |
| `docs` | Documentation only changes |
| `style` | Changes that don't affect code meaning |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `perf` | Performance improvement |
| `test` | Adding or correcting tests |
| `chore` | Changes to build process or auxiliary tools |
| `ci` | CI configuration changes |

### Examples

```bash
# Feature
git commit -m "feat(bus): add topic pattern matching"

# Bug fix
git commit -m "fix(dispatch): resolve message ordering issue"

# Breaking change
git commit -m "feat(api)!: change subscription return type"
```

The hook will reject non-conforming commits, ensuring a clean changelog can be generated automatically.

## Pull Request Process

1. **Before Submitting**
   - Run the full quality check suite: `mix quality`
   - Ensure all tests pass
   - Update documentation if needed
   - Add tests for new functionality

2. **PR Guidelines**
   - Create a feature branch from `main`
   - Use descriptive commit messages following conventional commits
   - Reference any related issues
   - Keep changes focused and atomic

3. **Review Process**
   - PRs require at least one review
   - Address all review comments
   - Maintain a clean commit history
   - Update your branch if needed

## Release Process

Releases are handled automatically by maintainers using `git_ops`. Contributors should:

1. **Use Conventional Commits** - Your commit messages determine changelog entries:
   - `feat:` commits create "Added" entries
   - `fix:` commits create "Fixed" entries
   - `docs:`, `chore:`, `ci:` commits are excluded

2. **Do NOT edit `CHANGELOG.md`** - It is auto-generated during releases

3. **Documentation**
   - Update guides if needed
   - Check all docstrings
   - Verify README is current

## Additional Resources

- [Hex Documentation](https://hexdocs.pm/jido_signal)
- [GitHub Issues](https://github.com/agentjido/jido_signal/issues)
- [GitHub Discussions](https://github.com/agentjido/jido_signal/discussions)

## Questions or Problems?

If you have questions about contributing:
- Open a GitHub Discussion
- Check existing issues
- Review the guides directory

Thank you for contributing to Jido Signal!
