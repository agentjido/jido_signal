# Core Concepts

A Signal describes an event. Routing selects targets. Dispatch delivers the
Signal. A Bus connects local publishers and subscribers and keeps records for
replay.

Read this guide after [Getting Started](getting-started.md). It explains how
the parts fit together before you choose an API.

## The Public Parts

| Part | What it is | Use it to |
| --- | --- | --- |
| `Jido.Signal` | An event envelope with a type, source, ID, and data. | Describe what happened and validate event data. |
| `Jido.Signal.Serialization` | Conversion between Signals and wire formats. | Exchange Signals as canonical maps, JSON, or Erlang terms. |
| `Jido.Signal.Router` | A value that maps type patterns to ordered targets. | Select targets without running them. |
| `Jido.Signal.Dispatch` | A delivery boundary with adapters. | Send a Signal to a process, logger, HTTP endpoint, or PubSub topic. |
| `Jido.Signal.Bus` | A local process with subscriptions and a Store. | Publish Signals, replay records, and track durable acknowledgements. |

These parts can be used separately. You do not need a Bus to create, route,
serialize, or dispatch a Signal.

## Signals: Events As Data

A typed Signal module gives one event a name and a data schema:

```elixir
defmodule ConceptGuide.OrderPlaced do
  use Jido.Signal,
    type: "order.placed",
    default_source: "/orders",
    schema: Zoi.object(%{"order_id" => Zoi.string()})
end

{:ok, signal} = ConceptGuide.OrderPlaced.new(%{"order_id" => "order-42"})
```

Read the envelope in three parts:

- **Type** says what happened: `"order.placed"`.
- **Source** identifies the context where it happened: `"/orders"`.
- **Data** holds the event facts: `%{"order_id" => "order-42"}`.

The generated ID identifies the event. A Signal describes an event; creating
one does not run a handler or deliver a message.

Use a typed module for events your application owns. Use `Jido.Signal.new/1`
or `Jido.Signal.new/3` for generic envelopes at input boundaries. Generic
construction validates the envelope, not an application data schema. See
[Signals and Dispatch](signals-and-dispatch.md).

## Router: Select Targets

A Router returns targets for a Signal type:

```elixir
router = Jido.Signal.Router.new!([{"order.*", :order_handler}])
{:ok, [:order_handler]} = Jido.Signal.Router.route(router, signal)
```

The target can be an application value, such as `:order_handler`. The Router
returns it without calling it. Your application decides what that value means.
Wildcard `*` matches one type segment; `**` matches zero or more segments.

Use a Router when target selection must be separate from delivery. See
[Signal Router](signal-router.md).

## Dispatch: Deliver To A Known Target

Dispatch uses an adapter and its options:

```elixir
:ok =
  Jido.Signal.Dispatch.dispatch(
    signal,
    {:pid, target: self(), delivery_mode: :async}
  )

receive do
  {:signal, ^signal} -> :ok
end
```

Dispatch calls adapters in the calling process, in target-list order. The PID
adapter's `:async` mode sends a message. Its `:sync` mode waits for a local
GenServer reply. Neither mode adds retries or a durable acknowledgement.

A successful adapter call has the adapter's delivery meaning. It does not
provide a common guarantee that all receivers finished their work. See
[Dispatch Adapters](signals-and-dispatch.md#dispatch-adapters).

## Bus: Publish Without Naming Each Receiver

A Bus owns subscriptions. A publisher supplies Signals; the Bus finds matching
local receivers, stores the accepted batch, and sends messages.

```text
publisher -> Bus -> Store append -> matching subscribers
                         |
                         +-> retained records for replay
```

A stored record has a cursor. The cursor identifies its position in that Bus;
the Signal ID identifies the event. Publishing the same Signal twice creates
two records.

Normal subscriptions receive `{:signal, signal}`. Durable subscriptions receive
`{:signal, subscription_id, recorded_signal}` and must acknowledge the record's
cursor. Only one durable record is in flight per subscription. A replacement
consumer can receive an unacknowledged record again, so handlers must tolerate
duplicates.

Durable subscription state survives a consumer restart while the Bus and Store
remain available. The default memory Store loses state when the Bus stops.
Recovery across Bus or VM restarts requires a persistent Store supplied by your
application. See [Event Bus](event-bus.md).

## Serialization And Catalog: Cross A Data Boundary

```elixir
{:ok, json} = Jido.Signal.serialize(signal)
{:ok, decoded} = Jido.Signal.deserialize(json)
```

Serialization uses a canonical CloudEvents map with string keys. Use string
keys in domain data when it must travel as JSON.

Deserialization validates the envelope. It does not select a typed Signal module
or validate that module's domain schema. A `Jido.Signal.Catalog` adds that step:
it selects an explicitly registered definition by exact type and schema identity,
then validates data. The Catalog is a value, not a process or global registry.

See [Serialization](serialization.md) and [Typed Signal Catalog](catalog.md).

## Who Owns What

| Concern | Owner |
| --- | --- |
| Envelope and typed data validation | Signal constructors; Catalog for registered input definitions |
| Type matching and target order | Router |
| Adapter option validation and delivery calls | Dispatch |
| Local subscriptions, retained records, and durable cursors | Bus and its Store |
| Domain event schemas and duplicate-safe handlers | Your application |
| Retry policy, rate limits, dead-letter handling, and workload isolation | Your application |
| Persistent Store implementation and external resource lifecycle | Your application |

## Choose The Next Guide

| I want to | Read |
| --- | --- |
| Define events and send to a known destination | [Signals and Dispatch](signals-and-dispatch.md) |
| Select handlers by event type | [Signal Router](signal-router.md) |
| Publish to local subscribers or replay records | [Event Bus](event-bus.md) |
| Store or exchange event data | [Serialization](serialization.md) |
| Validate incoming events against known definitions | [Typed Signal Catalog](catalog.md) |
| Carry trace or other transport metadata | [CloudEvents Context Attributes](signal-extensions.md) |
| Add an adapter or test delivery behavior | [Advanced Usage](advanced.md) |
