# Signal Router
<!-- covers: jido_signal.guides.signal_router -->

`Jido.Signal.Router` maps Signal type patterns to ordered targets. It performs
lookup only. It does not execute targets or validate Dispatch configuration.
It emits no telemetry. Instrument the caller when route timing is useful.

The Router compiles exact paths into a map and wildcard paths into a private
segment trie. The trie tracks exact, `*`, and `**` transitions. `**` traversal
memoizes node and segment positions so the same state is not processed twice.
The index is an implementation detail.

## Create a Router

The short tuple forms are the easiest way to define routes:

```elixir
alias Jido.Signal.Router

router =
  Router.new!([
    {"user.created", HandleUserCreated},
    {"user.*", HandleUserEvent},
    {"audit.**", AuditEvent, -50}
  ])
```

Use `new/2` when configuration errors must be returned:

```elixir
{:ok, router} = Router.new([{"user.created", HandleUserCreated}])
```

## Typed Signal Modules

A `use Jido.Signal` module is a valid route path when its `type/0` value is an
exact path. The Router stores this value as an exact path. Use strings for
wildcard routes.

```elixir
defmodule MyApp.UserCreated do
  use Jido.Signal,
    type: "user.created",
    default_source: "/accounts"
end

router = Router.new!([
  {MyApp.UserCreated, HandleUserCreated},
  {"user.*", HandleUserEvent}
])

{:ok, signal} = MyApp.UserCreated.new(%{user_id: "123"})
{:ok, [HandleUserCreated, HandleUserEvent]} = Router.route(router, signal)
```

`Router.path/1` resolves a string or Signal module to a path string.
`has_route?/2`, `remove/2`, `matches?/2`, and `filter/2` accept the same
values.

## Router Modules

`use Jido.Signal.Router` compiles the same specifications into a module. It
does not use Spark. Each `route` is one `new/1` specification. Match
predicates in this compiled form must be `{Module, :function, args}` MFA
values so the Router can be stored in the module. Anonymous functions remain
valid only for runtime `new/1` and `add/2`.

```elixir
defmodule MyApp.UserRouter do
  use Jido.Signal.Router

  route MyApp.UserCreated, HandleUserCreated
  route "user.*", HandleUserEvent
  route "audit.**", AuditEvent, -50
  route "job.completed", {MyApp.Filter, :important?, []}, :notify
end

{:ok, targets} = MyApp.UserRouter.route(signal)
MyApp.UserRouter.router()
MyApp.UserRouter.routes()
```

An empty module is a valid empty Router. Invalid paths, non-Signal module
paths, Signal module types with wildcards, and anonymous match functions fail
compilation. Route declarations can use module attributes for paths,
priorities, and MFA arguments.

## Path Patterns

An exact path matches one Signal type:

```elixir
{"user.created", HandleUserCreated}
```

`*` matches exactly one segment:

```elixir
{"user.*.updated", HandleUpdate}
```

This matches `user.profile.updated`. It does not match
`user.profile.settings.updated`.

`**` matches zero or more segments:

```elixir
{"audit.**", AuditEvent}
{"user.**.created", HandleCreated}
```

The second route matches both `user.created` and
`user.profile.address.created`.

Paths use dot-separated alphanumeric, underscore, or hyphen segments.
Consecutive dots and consecutive `**` segments are invalid.

## Route a Signal

```elixir
signal = Jido.Signal.new!(type: "user.created", source: "/example")

{:ok, targets} = Router.route(router, signal)
#=> {:ok, [HandleUserCreated, HandleUserEvent]}
```

No match returns a structured `Jido.Signal.Error.RoutingError`. The Router does
not return `{:ok, []}`.

## Precedence

The result order is deterministic:

1. Exact paths
2. Paths with `*`
3. Paths with `**`
4. More complex patterns
5. Higher priority
6. Earlier registration

Priority is an integer from `-100` through `100`. It changes order only when
the path class and complexity are equal.

```elixir
router =
  Router.new!([
    {"user.created", :normal, 0},
    {"user.created", :urgent, 100}
  ])

{:ok, [:urgent, :normal]} = Router.route(router, signal)
```

## Conditional Routes

`Route.match` is an optional runtime predicate. It runs after the path matches
and must return `true`. Runtime routers accept a unary function or a
`{Module, :function, args}` MFA. The Signal is prepended to the MFA args.
Compiled `use Jido.Signal.Router` modules accept only the MFA form.

```elixir
large_payment? = fn signal -> signal.data.amount > 1_000 end

{:ok, router} =
  Router.add(
    router,
    {"payment.processed", large_payment?, HandleLargePayment, 50}
  )

{:ok, router} =
  Router.add(
    router,
    {"payment.processed", {MyApp.Filter, :amount_gt?, [1_000]}, HandleLargePayment, 50}
  )
```

Router creation checks the predicate shape but does not execute it. A predicate
that raises or returns a value other than `true` does not match.

## Manage Routes

Add one route or a list of routes:

```elixir
{:ok, router} =
  Router.add(router, [
    {"metrics.**", MetricsHandler},
    {"system.error", ErrorHandler}
  ])
```

Remove all routes at one or more paths:

```elixir
{:ok, router} = Router.remove(router, ["metrics.**", "old.route"])
```

Inspect the public state without reading Router fields:

```elixir
2 = Router.count(router)
false = Router.empty?(router)
true = Router.has_route?(router, "system.error")
{:ok, routes} = Router.list(router)
```

`list/1` returns `%Jido.Signal.Router.Route{}` values in registration order.
`merge/2` appends the routes from another Router or a list of Route values.
`count/1` counts Route values. A Route with a list of targets counts as one.

## Pattern Helpers

Use the same matcher without creating a Router:

```elixir
true = Router.matches?("user.created", "user.*")
true = Router.matches?("audit.user.login", "audit.**")
false = Router.matches?("user.profile.updated", "user.*")

matching_signals = Router.filter(signals, "user.**")
```

`route/2`, `matches?/2`, and `filter/2` use the same pattern implementation.

## Route Values

Use `%Jido.Signal.Router.Route{}` when code needs an explicit value:

```elixir
route = %Jido.Signal.Router.Route{
  path: "user.created",
  target: HandleUserCreated,
  priority: 25
}

{:ok, route} = Jido.Signal.Router.validate(route)
```

The Route schema uses Zoi. Router targets remain generic terms. Dispatch
validates a target when delivery starts.
