# Getting Started
<!-- covers: jido_signal.guides.getting_started -->

Quick setup and first signal dispatch for the Jido Signal library.

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:jido_signal, "~> 3.0.0-beta.3"}
  ]
end
```

## Application Setup

Add the Signal Bus to your application's supervision tree:

```elixir
# In your application.ex
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Jido.Signal's internal supervisor starts automatically
      # Add your Signal Bus(es) here
      {Jido.Signal.Bus, name: :my_bus}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

For applications with multiple Buses or different replay bounds:

```elixir
children = [
  {Jido.Signal.Bus, name: :events_bus},
  {Jido.Signal.Bus,
    name: :audit_bus,
    max_log_size: 20_000
  }
]
```

## Create a Signal

Basic signal creation (preferred):

```elixir
# Preferred: positional constructor (type, data, attrs)
{:ok, signal} = Jido.Signal.new("user.created", %{user_id: "123", email: "user@example.com"},
  source: "/auth/registration"
)
```

Also available:

```elixir
# Map/keyword constructor (backwards compatible)
{:ok, signal} = Jido.Signal.new(%{
  type: "user.created",
  source: "/auth/registration",
  data: %{user_id: "123", email: "user@example.com"}
})
```

## Dispatch to a Process

Synchronous dispatch to PID:

```elixir
config = {:pid, [target: pid, delivery_mode: :sync]}
:ok = Jido.Signal.Dispatch.dispatch(signal, config)
```

Asynchronous dispatch:

```elixir
config = {:pid, [target: pid, delivery_mode: :async]}
:ok = Jido.Signal.Dispatch.dispatch(signal, config)
# Process receives: {:signal, signal}
```

Named process dispatch uses the same local-process adapter as PID dispatch:

```elixir
config = {:pid, [target: {:name, :my_process}, delivery_mode: :async]}
:ok = Jido.Signal.Dispatch.dispatch(signal, config)
```

The v2 `:named` adapter name is still accepted as a compatibility alias. Use
`:pid` for new code.

Multiple destinations:

```elixir
configs = [
  {:pid, [target: pid1, delivery_mode: :async]},
  {:logger, [level: :info]}
]
:ok = Jido.Signal.Dispatch.dispatch(signal, configs)
```

## Basic Error Handling

Dispatch returns raw error atoms by default:

```elixir
case Jido.Signal.Dispatch.dispatch(signal, config) do
  :ok -> 
    :success
  {:error, reason} ->
    Logger.error("Dispatch failed: #{inspect(reason)}")
    {:error, :dispatch_failed}
end
```

Signal creation errors:

```elixir
case Jido.Signal.new(%{type: "", source: "/test"}) do
  {:ok, signal} -> 
    signal
  {:error, reason} ->
    Logger.error("Invalid signal: #{reason}")
    {:error, :invalid_signal}
end
```

Process not alive:

```elixir
config = {:pid, [target: dead_pid, delivery_mode: :async]}
{:error, :process_not_alive} = Jido.Signal.Dispatch.dispatch(signal, config)
```

## Scoped Buses

Use `jido:` to isolate a Bus name for an application domain or test:

```elixir
{:ok, _} = Jido.Signal.Bus.start_link(name: :my_bus, jido: MyApp.Jido)
{:ok, bus} = Jido.Signal.Bus.whereis(:my_bus, jido: MyApp.Jido)
```

The package Registry uses `{MyApp.Jido, "my_bus"}` as the key. No separate
instance supervisor or Registry is necessary.

See [Event Bus](event-bus.md#scoped-buses) for complete examples.

## Next Steps

- [Signals and Dispatch](signals-and-dispatch.md) - Signal structure, dispatch adapters, and custom signal types
- [Event Bus](event-bus.md) - Pub/sub, durable subscriptions, replay, Store, and scoped Buses
- [Serialization](serialization.md) - Canonical maps and binary formats for application-owned storage
