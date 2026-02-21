# Getting Started

Quick setup and first signal dispatch for the Jido Signal library.

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:jido_signal, "~> 2.0"}
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

For applications with multiple buses or custom middleware:

```elixir
children = [
  {Jido.Signal.Bus, name: :events_bus},
  {Jido.Signal.Bus, 
    name: :audit_bus,
    middleware: [{Jido.Signal.Bus.Middleware.Logger, level: :info}]
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

Named process dispatch:

```elixir
config = {:named, [target: {:name, :my_process}, delivery_mode: :async]}
:ok = Jido.Signal.Dispatch.dispatch(signal, config)
```

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

## Instance Isolation

For multi-tenant applications or isolated testing, start an isolated instance:

```elixir
# Start isolated instance
{:ok, _} = Jido.Signal.Instance.start_link(name: MyApp.Jido)

# Start bus scoped to the instance
{:ok, _} = Jido.Signal.Bus.start_link(name: :my_bus, jido: MyApp.Jido)
```

See [Event Bus](event-bus.md#instance-isolation) for complete multi-tenant examples.

## Next Steps

- [Signals and Dispatch](signals-and-dispatch.md) - Deep dive into signal structure, dispatch adapters, circuit breakers, and custom signal types
- [Event Bus](event-bus.md) - Pub/sub messaging, persistent subscriptions, Dead Letter Queue, instance isolation, and horizontal scaling
- [Signal Journal](signal-journal.md) - Persistence adapters (ETS, Mnesia), checkpointing, and causality tracking
