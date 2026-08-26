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

Typed Signals accept Zoi schemas only:

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

Zoi schemas must be static module data. Replace anonymous refinement,
transform, and callback functions with named `{Module, :function, args}` MFA
values. Lazy schemas are not supported. The compiler rejects these values when
it expands `use Jido.Signal`.

## Make Envelope Semantics Explicit

Jido generates a UUID7 only when it creates a new Signal ID. It accepts any
non-empty external ID when it reads a Signal.

The CloudEvents wire `specversion` is `"1.0"`. The old `"1.0.2"` value named a
specification document patch. The v3 reader accepts that old value and
normalizes it to `"1.0"`.

Generic construction now requires `source`. Typed Signals can supply a
`default_source`. Jido no longer infers source from the call stack. Jido also
does not create an event time or infer `application/json`. Supply `time` and
`datacontenttype` only when they are known.

## Use the Canonical Signal Map

Use `Jido.Signal.to_map/1` and `Jido.Signal.from_map/1` for storage and transport
boundaries. Do not read the Signal struct as a wire map.

```elixir
map = Jido.Signal.to_map(signal)
{:ok, signal} = Jido.Signal.from_map(map)
```

The v3 writer uses string keys, omits nil optional fields, and flattens valid
CloudEvents context attributes. It does not add a Jido-specific wire marker.
The reader accepts legacy `jido_schema_version` 1 and 2 payloads.

The removed `jido_dispatch` field is not Signal metadata. Move dispatch targets
to Bus subscriptions or pass them directly to `Jido.Signal.Dispatch`.

You can use the Serialization entry module:

```elixir
{:ok, binary} = Jido.Signal.Serialization.serialize(signal)
{:ok, signal} = Jido.Signal.Serialization.deserialize(binary)

{:ok, binary} = Jido.Signal.Serialization.serialize(signal, format: :erlang_term)
{:ok, signal} = Jido.Signal.Serialization.deserialize(binary, format: :erlang_term)
```

Serialization accepts Signals only. The v2 serializer behavior, type providers,
JSON decoder protocol, runtime serializer configuration, and MessagePack format
are removed. Convert stored MessagePack values to JSON or Erlang Term Format
before the upgrade.

JSON-safe Signal data uses `data`. Binary data and other Erlang-only terms use
`data_base64`. Jido creates that value with `:erlang.term_to_binary/1` and
`Base.encode64/1`. The reader uses the safe Erlang term option.

## Tighten Trace Context

`Jido.Signal.Trace` is now the trace value and Signal carrier API. The nested
`Jido.Signal.Trace.Context` struct and the process-dictionary-based
`Jido.Signal.TraceContext` module are removed.

```elixir
trace = Jido.Signal.Trace.new(trace_flags: "01")
{:ok, signal} = Jido.Signal.Trace.put(signal, trace)

child = Jido.Signal.Trace.child(trace)
{:ok, outgoing_signal} = Jido.Signal.Trace.put(outgoing_signal, child)
```

The Trace value keeps `trace_id`, `span_id`, `trace_flags`, and optional
`tracestate`. It does not keep `parent_span_id` or `causation_id`. Use an
application-owned Signal context attribute when you need causal correlation.

Jido Signal does not select sampling policy. New Trace values use `"00"` flags
unless the caller supplies another valid value. Incoming flags are preserved.
The application or tracing system owns process context and span lifetime.

## Replace Schema-backed Signal Extensions

The `Jido.Signal.Ext` behavior and extension registry are removed. Use a custom
Signal module with a Zoi schema for domain data:

```elixir
defmodule MyApp.PaymentCaptured do
  use Jido.Signal,
    type: "payment.captured",
    default_source: "/billing",
    schema: Zoi.object(%{payment_id: Zoi.string()})
end
```

CloudEvents extension context attributes remain available for small routing or
processing metadata:

```elixir
{:ok, signal} = Jido.Signal.put_context(signal, "tenantid", "tenant-123")
```

Context names contain only lower-case letters and digits, start with a letter,
and have at most 20 characters. Values must use a CloudEvents context type.
Maps, lists, tuples, PIDs, and dispatch configurations are not valid context
values.

## Keep Router Precedence

Router precedence is unchanged:

1. Exact paths run before `*` paths.
2. `*` paths run before `**` paths.
3. More specific paths run before less specific paths.
4. Higher priority runs before lower priority for equal specificity.
5. Registration order breaks the final tie.

The exact-path map, wildcard trie, Router state, and matcher implementation are internal. Use
`Jido.Signal.Router` and `Jido.Signal.Router.Route` only. Use `count/1`,
`empty?/1`, `list/1`, and `has_route?/2` instead of reading Router fields.
`count/1` counts Route values, not the number of targets inside each Route.

`Route.match` remains supported. Router creation checks its arity but does not
execute it. A match function that raises or does not return `true` is treated
as no match during routing.

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
