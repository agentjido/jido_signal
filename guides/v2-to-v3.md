# Migrate from v2 to v3
<!-- covers: jido_signal.guides.v2_to_v3 -->

Jido Signal v3 has five primary public areas: Signal, Serialization, Router,
Dispatch, and Bus. It uses Zoi for package schemas. It removes the general
Journal and several runtime policy features.

This guide starts at
[v2.2.2](https://github.com/agentjido/jido_signal/tree/v2.2.2). If your
application uses an older v2 release, record its local behavior before you
start the upgrade. See the [v3 README](../README.md) for the new public API.

## Understand the Change

| Area | v2.2.2 | v3 |
| --- | --- | --- |
| Signal schemas | NimbleOptions and duplicate validation paths | Zoi only, with MFA callback values in schemas |
| Wire format | Serializer framework, custom markers, and MessagePack | Canonical CloudEvents 1.0 maps, JSON, and safe Erlang terms |
| Router | Large routing engine and cache | Exact-path map and compact wildcard trie |
| Dispatch | Async, batch, retry, Fuse, and many adapters | Ordered delivery and a small adapter set |
| Bus | Journal, partitions, middleware, snapshots, and dead-letter policy | Local ordered delivery, retained replay, durable cursors, and a Store seam |
| Trace and extensions | Nested trace state and a schema extension registry | Explicit Trace values and flat CloudEvents context attributes |

The main Signal, Router, Dispatch, and Bus boundaries continue in v3. Most
removed APIs were policy systems inside those boundaries.

## Use This Migration Order

1. Find removed modules, options, and custom Dispatch adapters.
2. Convert stored MessagePack and Journal data while the v2 readers are still available.
3. Convert typed Signal schemas and custom Dispatch adapter schemas to Zoi.
4. Update Signal creation and wire boundaries.
5. Update Router, Dispatch, and Bus use.
6. Run v2 fixture tests and failure-path tests before deployment.

## Upgrade the Dependency

```elixir
def deps do
  [
    {:jido_signal, "~> 3.0.0-beta.3"}
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
modules. Typed Signal `validate_data/1` and `new/2` calls return the Zoi parse
result directly. `new!/2` raises the Zoi parse exception when data validation
fails.

Custom Signal schemas can accept any data value. They do not have an
Action-style map requirement.

Zoi schemas must be static module data. Replace anonymous refinement,
transform, and callback functions with named `{Module, :function, args}` MFA
values. Lazy schemas are not supported. The compiler rejects these values when
it expands `use Jido.Signal`.

Typed Signal modules expose `type/0`, `default_source/0`,
`datacontenttype/0`, `dataschema/0`, and `schema/0`. The old `metadata/0` and
generated `to_json/0` functions are removed.

## Make Envelope Semantics Explicit

Jido generates a UUID7 only when it creates a new Signal ID. It accepts any
non-empty external ID when it reads a Signal.

`Jido.Signal.ID` now contains only `generate/0`, `generate!/0`,
`extract_timestamp/1`, `compare/2`, and `valid?/1`. Remove calls to the old
sequential, batch, sequence-number, and sortable-format helpers. UUID7 values
created in the same millisecond have random order.

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

The removed `jido_dispatch` field is not Signal metadata. Use `target: pid` for
a local Bus subscription or pass adapter targets to `Jido.Signal.Dispatch`.

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

JSON-safe Signal data uses `data`. Non-UTF-8 binary data uses `data_base64`.
Jido applies `Base.encode64/1` directly to the raw bytes. JSON serialization
rejects other Erlang-only terms. The trusted Erlang Term Format keeps them in
`data` and uses the safe Erlang term decode option.

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

The v3 Router performs lookup only and emits no telemetry. Instrument the
caller when route timing is useful.

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
The HTTP adapter sends structured CloudEvents JSON with OTP `:httpc`. It does
not follow redirects, and it accepts only `url`, `headers`, and `timeout`.
Dispatch adds no retry loop. OTP `:httpc` can still honor `Retry-After` on a
503 response, and OTP 27 has no option to disable that client behavior. Use a
custom adapter when strict single-attempt delivery is required. The old
`method`, `retry`, and `ssl_options` options are removed. The
proprietary Webhook adapter is also removed; use a custom adapter when an
endpoint needs request signing.

Treat HTTP URLs as trusted application configuration. The built-in adapter
permits private network targets and does not protect against DNS rebinding.
OTP 27 `:httpc` has no response body size limit for these requests. Use a
custom adapter for untrusted targets or a strict response size limit.

### Update Custom Dispatch Adapters

In v2, each custom adapter parsed its own options with `validate_opts/1`:

```elixir
defmodule MyApp.CustomAdapter do
  @behaviour Jido.Signal.Dispatch.Adapter

  @impl true
  def validate_opts(opts), do: MyApp.Options.validate(opts)

  @impl true
  def deliver(signal, opts), do: MyApp.Client.send(signal, opts)
end
```

In v3, the adapter returns a Zoi schema. Dispatch parses the options before it
calls `deliver/2`:

```elixir
defmodule MyApp.CustomAdapter do
  @behaviour Jido.Signal.Dispatch.Adapter

  @impl true
  def options_schema do
    Zoi.keyword(
      [url: Zoi.string() |> Zoi.required()],
      unrecognized_keys: :error
    )
  end

  @impl true
  def deliver(signal, opts) do
    MyApp.Client.send(signal, Keyword.fetch!(opts, :url))
  end
end
```

Remove `validate_opts/1`. Add `options_schema/0`. Keep unknown keys as errors
unless the adapter has a clear reason to accept them.

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

`Jido.Signal.Util` is removed. Use `Jido.Signal.Bus.via_tuple/2` and
`Jido.Signal.Bus.whereis/2` for Bus registration and lookup. The package
name-resolution and value-sanitization helpers are internal and are not
application APIs.

`Jido.Signal.Instance` and `Jido.Signal.Names` are removed. The `jido:` Bus
option is now a Registry namespace. The package stores a scoped Bus under a
`{jido, bus_name}` key in `Jido.Signal.Registry`. No separate instance process
or Registry is necessary.

### Replay and Storage

v2 replay started at a timestamp:

```elixir
{:ok, records} =
  Jido.Signal.Bus.replay(:events, "user.**", start_timestamp, limit: 100)
```

v3 replay starts after a Store cursor and stays behind the Bus-owned Store
boundary:

```elixir
{:ok, records} =
  Jido.Signal.Bus.replay(:events, "user.**", after: 0, limit: 100)
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

Store records and durable subscription definitions use `"format_version" =>
1`. The Store also owns the latest cursor. Store startup failures stop Bus
startup. The Bus does not silently use memory storage.

### Durable Subscriptions and Acknowledgements

Replace `persistent?` with a stable durable string ID:

```elixir
{:ok, "payments-agent"} =
  Jido.Signal.Bus.subscribe(:events, "payment.*",
    durable: "payments-agent"
  )

{:ok, [_published]} = Jido.Signal.Bus.publish(:events, [payment_signal])

receive do
  {:signal, "payments-agent", recorded} ->
    :ok = handle_payment(recorded.signal)
    :ok = Jido.Signal.Bus.ack(:events, "payments-agent", recorded.cursor)
end
```

A durable subscription has one active process and one record in flight. Only
that process can acknowledge the current cursor. The Bus stores the record
before delivery. If the process exits before acknowledgement, call
`subscribe/3` from the replacement process with the same durable ID and path.
The Bus sends the record again, so handlers must be idempotent.

`unsubscribe/3` detaches a durable target but keeps its definition.
`delete_subscription/2` permanently removes the definition and cursor.

The old `persistent?`, `persistent`, `reconnect/3`, record-ID and Signal-ID
acknowledgement, `max_in_flight`, `max_pending`, `max_attempts`, and
`retry_interval` contracts are removed.

### Bus Targets and Runtime Policy

Bus subscriptions now accept only a local process target:

```elixir
Jido.Signal.Bus.subscribe(:events, "user.*", target: handler_pid)
```

Subscription `dispatch:` targets and multi-target lists are removed. Use
`Jido.Signal.Dispatch` directly for HTTP, PubSub, Logger, or other adapters.

Bus middleware, retry timers, negative acknowledgement, dead-letter queues,
leases, and competing-consumer policy are removed. The application that owns
the work must provide these policies.

### Removed Bus Features

Remove these startup options and calls:

- `journal_adapter`, `journal_adapter_opts`, and `journal_pid`;
- `partition_count` and partition rate-limit options;
- snapshot create, read, list, and delete functions;
- Bus middleware and its Task Supervisor;
- `dlq_entries/2`, `redrive_dlq/3`, and `clear_dlq/2`;
- public Bus state and persistent worker access.

The v3 Bus accepts only its documented startup options. Unknown options return
an `:invalid_options` error. Use separate Bus processes for workload isolation.
Use cursor-based `replay/3` instead of snapshots.

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

Use a custom Bus Store only for Bus replay records, the latest cursor, and
durable subscription definitions.
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
  [:jido, :signal, :bus, :deliver],
  fn event, measurements, metadata, test_pid ->
    send(test_pid, {event, measurements, metadata})
  end,
  self()
)
```

Detach the handler when the test finishes.

## Check the Compatibility Boundary

v3 keeps these compatibility contracts:

- Signal map and keyword constructors;
- Router exact, `*`, and `**` precedence;
- Dispatch `{adapter, options}` tuples;
- `:named` Dispatch input as an alias for the local process adapter;
- reads of wire `specversion` value `"1.0.2"`;
- reads of legacy `jido_schema_version` 1 and 2 maps.

v3 does not write the old wire form. It does not read MessagePack, restore a
Journal, or run removed retry, partition, snapshot, middleware, and dead-letter
policy. Convert that state before you deploy v3.

## Final Check

Before deployment:

1. Read old serialized fixtures with v3.
2. Remove all NimbleOptions, Fuse, Journal, partition, and snapshot references.
3. Confirm that each generic Signal constructor supplies `source`.
4. Confirm that typed Signal schemas use static Zoi data and MFA callbacks.
5. Confirm that custom Dispatch adapters return a Zoi schema.
6. Test exact, `*`, and `**` route precedence.
7. Test each Dispatch tuple that your application uses.
8. Test Bus target exit, durable reattachment, replay bounds, and cursor acknowledgement order.
9. Confirm that a selected durable Store fails startup clearly when unavailable.
