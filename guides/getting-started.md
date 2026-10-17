# Getting Started
<!-- covers: jido_signal.guides.getting_started -->

This guide introduces three steps: define an event, create a Signal, and
deliver it. Then use a Bus when publishers must not name individual receivers.
Run the examples in order in an IEx session for your application.

## Install The Package

Add the dependency to `mix.exs`:

```elixir
def deps do
  [
    {:jido_signal, "~> 3.0.0-beta.5"}
  ]
end
```

Run `mix deps.get`, then start `iex -S mix`. The package starts its internal
supervisor automatically. Direct dispatch needs no Bus setup.

## Define An Event

A typed Signal module declares the event type, its default source, and a Zoi
schema for its data:

```elixir
defmodule GettingStarted.UserCreated do
  use Jido.Signal,
    type: "user.created",
    default_source: "/accounts",
    schema: Zoi.object(%{"user_id" => Zoi.string()})
end
```

The type says what happened. The source identifies where it happened. The data
contains the event facts. String keys let this data travel as JSON.

## Create A Signal

```elixir
{:ok, signal} = GettingStarted.UserCreated.new(%{"user_id" => "user-123"})
```

The constructor validates the data and adds a generated ID. Invalid data
returns an error before delivery:

```elixir
{:error, _errors} = GettingStarted.UserCreated.new(%{"user_id" => 123})
```

Creating a Signal does not send it. Use `Jido.Signal.new/1` or `new/3` when you
need a generic envelope without a typed domain schema. See
[Signals and Dispatch](signals-and-dispatch.md#signal-structure).

## Deliver To A Process

The PID adapter can send to the current process, so this example needs no
separate receiver:

```elixir
:ok =
  Jido.Signal.Dispatch.dispatch(
    signal,
    {:pid, target: self(), delivery_mode: :async}
  )

receive do
  {:signal, ^signal} -> :received
end
```

`:ok` confirms the send operation. The `receive` confirms that the message
arrived. A different receiver must run its own handler.

Use `delivery_mode: :sync` when a local GenServer must reply before Dispatch
returns. It must handle `handle_call({:signal, signal}, from, state)`. See
[PID Adapter](signals-and-dispatch.md#pid-adapter).

## Publish Through A Bus

A Bus lets receivers subscribe by type. Start this example Bus, subscribe the
current process, then publish the Signal:

```elixir
{:ok, bus} = Jido.Signal.Bus.start_link(name: :getting_started_bus)
{:ok, subscription_id} = Jido.Signal.Bus.subscribe(bus, "user.*")
{:ok, [recorded]} = Jido.Signal.Bus.publish(bus, [signal])

receive do
  {:signal, ^signal} -> :received
end
```

`"user.*"` matches one segment after `"user"`, including `"user.created"`.
`recorded` holds the Signal and its Bus cursor. The Bus stores the accepted
batch before sending messages. A normal subscription does not acknowledge
processing or retry delivery.

Clean up the example:

```elixir
:ok = Jido.Signal.Bus.unsubscribe(bus, subscription_id)
GenServer.stop(bus)
```

In an application, put the Bus under your supervisor instead of starting it
from a caller:

```elixir
children = [
  {Jido.Signal.Bus, name: :events_bus}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

The default Store is bounded and in memory. Read [Event Bus](event-bus.md)
for replay, durable subscriptions, scoped names, and restart limits.

## Next Steps

- [Core Concepts](concepts.md) explains how the public parts fit together.
- [Signals and Dispatch](signals-and-dispatch.md) covers envelopes, typed definitions, and adapters.
- [Event Bus](event-bus.md) covers subscriptions and recovery rules.
- [Serialization](serialization.md) covers canonical maps, JSON, and Erlang terms.
