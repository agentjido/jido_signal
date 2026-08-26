# Migrate from v2 to v3
<!-- covers: jido_signal.guides.v2_to_v3 -->

Jido Signal v3 has five primary public areas: Signal, Serialization, Router,
Dispatch, and Bus. It uses Zoi for package schemas. It removes the general
Journal and several runtime policy features.

## Upgrade the Dependency

```elixir
def deps do
  [
    {:jido_signal, "~> 3.0"}
  ]
end
```

Use Elixir 1.18 or later and OTP 27 or later.

## Replace NimbleOptions Schemas with Zoi

Typed Signals and extensions now accept Zoi schemas only:

```elixir
defmodule MyApp.UserCreated do
  use Jido.Signal,
    type: "user.created",
    default_source: "/users",
    schema: Zoi.object(%{
      user_id: Zoi.string(),
      email: Zoi.string()
    })
end
```

Remove NimbleOptions schema declarations and error conversion from your Signal
modules. Zoi errors pass through the Jido Signal structured error boundary.

## Use the Canonical Signal Map

Use `Jido.Signal.to_map/1` and `Jido.Signal.from_map/1` for storage and transport
boundaries. Do not read the Signal struct as a wire map.

```elixir
map = Jido.Signal.to_map(signal)
{:ok, signal} = Jido.Signal.from_map(map)
```

The v3 writer adds `"jido_schema_version" => 2`. It uses string keys, omits nil
optional fields, and flattens extension attributes. The reader accepts version 1,
version 2, and unversioned v2 payloads.

The removed `jido_dispatch` field is read as the `"dispatch"` extension for old
payloads. New payloads do not write `jido_dispatch`.

You can use the Serialization entry module:

```elixir
{:ok, binary} = Jido.Signal.Serialization.serialize(signal)
{:ok, signal} = Jido.Signal.Serialization.deserialize(binary)
```

## Keep Router Precedence

Router precedence is unchanged:

1. Exact paths run before `*` paths.
2. `*` paths run before `**` paths.
3. More specific paths run before less specific paths.
4. Higher priority runs before lower priority for equal specificity.
5. Registration order breaks the final tie.

Router trie, matcher, container, and validator modules are internal. Use
`Jido.Signal.Router` and `Jido.Signal.Router.Route` only.

## Move Dispatch Runtime Policy to the Caller

Dispatch keeps target tuples and ordered synchronous delivery:

```elixir
:ok =
  Jido.Signal.Dispatch.dispatch(signal, [
    {:pid, target: handler_pid},
    {:logger, level: :info}
  ])
```

These APIs and options are removed:

- `dispatch_async/2`;
- `dispatch_batch/2`;
- `batch_size`;
- Dispatch concurrency limits;
- retry loops;
- Fuse and circuit-breaker state.

Start a Task in your application for asynchronous work. Put retry, concurrency,
rate-limit, and circuit-breaker policy in the application that owns the work.
The HTTP and webhook adapters make one request for each dispatch.

## Update Bus Configuration

The common Bus boundary stays:

```elixir
{:ok, _bus} = Jido.Signal.Bus.start_link(name: :events)
{:ok, subscription_id} = Jido.Signal.Bus.subscribe(:events, "user.*")
{:ok, records} = Jido.Signal.Bus.publish(:events, [signal])
:ok = Jido.Signal.Bus.unsubscribe(:events, subscription_id)
```

Bus implementation state is private. Do not call `:sys.get_state/1` or depend
on Bus state, subscriber, partition, or worker structs.

### Replay and Storage

Replay stays behind the Bus-owned Store boundary:

```elixir
{:ok, records} = Jido.Signal.Bus.replay(:events, "user.**", 0, batch_size: 100)
```

The default memory Store has a bounded log and does not survive a Bus restart.
For restart durability, implement `Jido.Signal.Bus.Store` and select it at Bus
startup:

```elixir
Jido.Signal.Bus.start_link(
  name: :events,
  store: MyApp.SignalStore,
  store_opts: [repo: MyApp.Repo]
)
```

Store records use `"format_version" => 1`. Store startup failures stop Bus
startup. The Bus does not silently use memory storage.

### Persistent Subscriptions and Acknowledgements

Persistent subscriptions stay, with a smaller contract:

```elixir
{:ok, subscription_id} =
  Jido.Signal.Bus.subscribe(:events, "payment.*",
    persistent?: true,
    start_from: :current,
    dispatch: {:pid, target: self()}
  )

{:ok, [recorded]} = Jido.Signal.Bus.publish(:events, [payment_signal])
:ok = Jido.Signal.Bus.ack(:events, subscription_id, recorded.id)
```

Acknowledge the `RecordedSignal.id` when the caller has it. A live subscriber
can acknowledge the delivered Signal envelope ID for v2 compatibility. The Bus
does not advance a checkpoint past an older unacknowledged record. Reconnect
gives at-least-once delivery, so consumers must handle duplicates.

The v2 options `max_in_flight`, `max_pending`, `max_attempts`, and
`retry_interval` have no v3 effect and must be removed. The Bus has no internal
retry or backpressure worker.

### DLQ

A failed persistent delivery moves directly to the Bus DLQ. Use
`dlq_entries/2`, `redrive_dlq/3`, and `clear_dlq/2`. A redrive is explicit. The
Bus does not run retry waves.

### Removed Bus Features

Remove these startup options and calls:

- `journal_adapter`, `journal_adapter_opts`, and `journal_pid`;
- `partition_count` and partition rate-limit options;
- snapshot create, read, list, and delete functions;
- public Bus state and persistent worker access.

Old Journal and partition startup options return
`{:unsupported_option, option}`. Use separate Bus processes for workload
isolation. Use `replay/4` instead of snapshots.

## Replace the Standalone Journal

v3 removes these modules:

- `Jido.Signal.Journal`;
- `Jido.Signal.Journal.Persistence`;
- Journal in-memory, ETS, and Mnesia adapters;
- Journal cause, effect, conversation, checkpoint, and DLQ APIs.

There is no automatic conversion for causal or conversation data. Move this
data to an application-owned database before you upgrade. Keep Signal IDs and
the old cause and conversation fields as explicit columns or records in that
database.

Use a custom Bus Store only for Bus replay records, checkpoints, and DLQ data.
Do not use the Bus Store as a general causal graph API.

## Replace the Pure Registry API

The pure `Jido.Signal.Registry` struct API is removed. Use Router for in-memory
pattern lookup or Bus for live subscriptions:

```elixir
router = Jido.Signal.Router.new!([{"user.*", :user_handler}])
{:ok, [:user_handler]} = Jido.Signal.Router.route(router, signal)
```

The internal OTP Registry process name can still contain
`Jido.Signal.Registry`. This process name is not the removed struct API.

## Replace BusSpy

`Jido.Signal.BusSpy` is removed. Tests can attach handlers to Bus telemetry
events directly:

```elixir
:telemetry.attach(
  "my-test-handler",
  [:jido, :signal, :bus, :after_dispatch],
  fn event, measurements, metadata, test_pid ->
    send(test_pid, {event, measurements, metadata})
  end,
  self()
)
```

Detach the handler when the test finishes.

## Final Check

Before deployment:

1. Read old serialized fixtures with v3.
2. Remove all NimbleOptions, Fuse, Journal, partition, and snapshot references.
3. Test exact, `*`, and `**` route precedence.
4. Test each Dispatch tuple that your application uses.
5. Test Bus target exit, reconnect, replay bound, acknowledgement order, and DLQ.
6. Confirm that a selected durable Store fails startup clearly when unavailable.
