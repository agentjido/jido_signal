# Event Bus
<!-- covers: jido_signal.guides.event_bus -->

The Event Bus provides ordered local publish and subscribe delivery. It uses
`Jido.Signal.Router` for type matching and a small Store for bounded replay and
durable subscription cursors.

## Start a Bus

Start the Bus under your application supervisor:

```elixir
children = [
  {Jido.Signal.Bus, name: :my_bus}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

The default memory Store keeps at most 100,000 records. Set `max_log_size` to
change the bound:

```elixir
{Jido.Signal.Bus, name: :my_bus, max_log_size: 20_000}
```

## Normal Subscriptions

The calling process is the default target:

```elixir
alias Jido.Signal
alias Jido.Signal.Bus

{:ok, subscription_id} = Bus.subscribe(:my_bus, "user.*")

signal = Signal.new!("user.created", %{user_id: "123"}, source: "/users")
{:ok, [recorded]} = Bus.publish(:my_bus, [signal])

receive do
  {:signal, ^signal} -> :ok
end

:ok = Bus.unsubscribe(:my_bus, subscription_id)
```

Use `target: pid` when another process must receive the message:

```elixir
{:ok, subscription_id} =
  Bus.subscribe(:my_bus, "user.*", target: subscriber_pid)
```

The Bus monitors the target. It removes a normal subscription when the target
exits.

Subscriptions select by Signal type by default. Use an exact type or a wildcard
type path, such as `"message.added"`, `"message.*"`, or `"sensor.**"`. Add an
optional `:selector` to match the source, subject, or both. The Bus sends the
original Signal after all selected fields match.

The Bus keeps Router precedence: exact paths, `*`, `**`, pattern complexity,
priority, and registration order. It sends each matching message from the Bus
process in that order.

## Select by Source and Subject

CloudEvents separates the event kind (`type`), occurrence context (`source`),
and the subject within that context (`subject`). The specification describes
subject filtering as useful for subscriptions that do not inspect domain data.
See the [CloudEvents context attributes](https://github.com/cloudevents/spec/blob/v1.0.2/cloudevents/spec.md#context-attributes).

For example, a warehouse observer can select stock changes for one item:

```elixir
{:ok, subscription_id} =
  Bus.subscribe(:my_bus, "inventory.stock.changed",
    selector: [source: "/warehouses/east", subject: "sku-42"]
  )
```

The type path uses the existing Router exact and wildcard rules. Source and
subject use exact, case-sensitive equality. All supplied conditions must match.
The same subject string can occur at different sources, so include `:source`
when the source is part of the required scope.

Either field can be used alone:

```elixir
Bus.subscribe(:my_bus, "inventory.**", selector: [source: "/warehouses/east"])
Bus.subscribe(:my_bus, "sensor.*", selector: [subject: "sensor-42"])
```

A messaging application can use the same interface if its Signal contract
identifies a room as the subject:

```elixir
Bus.subscribe(:my_bus, "message.added",
  target: room_observer_pid,
  selector: [source: "/messages", subject: "room-42"]
)
```

The application defines the meaning of its source and subject. The Bus has no
warehouse, sensor, room, or thread rules. Keep the meaning of each event type
stable across subjects. Use domain data for conditions such as stock thresholds
or message contents. Those conditions belong in the consumer.

### Validation and Delivery

- `:selector` is a non-empty keyword list. It accepts `:source`, `:subject`,
  or both, once each. The type is selected by the path argument.
- Each value is a non-empty string with at most 4,096 bytes. A source must be
  a valid URI-reference. A subject must be valid CloudEvents context text.
- Values are not normalized. There is no prefix, suffix, or wildcard matching
  for source and subject. A missing subject does not match a selected subject.
- IDs, time, content type, data schema, data, and extensions do not affect
  selection. Selection preserves the complete original Signal and its ID.
- An invalid selector returns `{:error, {:invalid_selector, message}}` and
  adds no subscription. This includes `nil`, an empty list, duplicate keys,
  unsupported fields, functions, MFAs, and invalid values. Omit `:selector`
  for the existing subscription that selects by type path only.

The Bus validates and compiles the selector once when it adds a subscription.
Router type indexing finds the candidate routes. A package-created predicate
then uses direct Signal pattern matching for the selected source and subject.
Delivery does not parse the selector, traverse payload maps, or run application
callbacks. The default subscription keeps its existing Router path.

Selected observations keep Router precedence and publication order. Unsubscribe,
deletion, and target exit remove the compiled predicate with its route. Selection
is trusted subscription configuration; it is not authorization. A Bus-published
command remains an observation.

### Durable and Replay Limits

Selectors apply to ordinary live subscriptions. `:selector` with `:durable`
returns `{:error, {:conflicting_options, [:selector, :durable]}}`, including
when a target attaches again. This does not change the stored durable definition
or cursor.

Replay selects only by type path and rejects `:selector` as an unsupported
option. Filtered durable delivery needs explicit stored selector identity,
version, cursor advancement, replay, reconnect, and restart rules.

## Durable Subscriptions

A durable subscription prevents an agent restart from losing an accepted
Signal. Give it a stable string ID:

```elixir
{:ok, "billing-agent"} =
  Bus.subscribe(:my_bus, "payment.*", durable: "billing-agent")
```

A durable target receives one record at a time:

```elixir
receive do
  {:signal, "billing-agent", recorded} ->
    :ok = MyApp.Billing.handle(recorded.signal)
    :ok = Bus.ack(:my_bus, "billing-agent", recorded.cursor)
end
```

The Bus stores the record before it sends this message. It sends the next
matching record only after the target acknowledges the current cursor.

Delivery is ordered and at least once. If the target exits before an
acknowledgement, attach the replacement process with the same ID and path:

```elixir
{:ok, "billing-agent"} =
  Bus.subscribe(:my_bus, "payment.*",
    durable: "billing-agent",
    target: replacement_pid
  )
```

The Bus sends the unacknowledged record again. The replacement cannot change
the path. Only one target can be active for a durable ID.

A new durable subscription starts at the current cursor. Use `:origin` or a
retained cursor to start earlier:

```elixir
Bus.subscribe(:my_bus, "payment.*",
  durable: "billing-rebuild",
  start_from: :origin
)
```

`unsubscribe/3` detaches the active target but keeps the durable definition and
cursor. `delete_subscription/2` permanently removes them:

```elixir
:ok = Bus.unsubscribe(:my_bus, "billing-agent")
:ok = Bus.delete_subscription(:my_bus, "billing-agent")
```

The Bus has no retry timer, negative acknowledgement, dead-letter queue,
lease, or competing-consumer policy. Put those policies in the application
that owns the work.

## Bounded Replay

Read retained records by cursor:

```elixir
{:ok, records} = Bus.replay(:my_bus, "user.**")
{:ok, next_page} = Bus.replay(:my_bus, "user.**", after: 100, limit: 50)
```

The `:after` cursor is exclusive. The default is `0`. The default `:limit` is
`:infinity`.

Each `Jido.Signal.Bus.RecordedSignal` has `id`, `cursor`, `type`, `created_at`,
and `signal` fields. Use the cursor for replay and durable acknowledgement.
Signal encoding remains in `Jido.Signal.Serialization`; RecordedSignal has no
separate serializer.

## Store Boundary

`Jido.Signal.Bus.Store.Memory` is the only included adapter. It does not survive
a Bus or VM restart.

A durable subscription can stop old matching records from leaving the bounded
log. If the Store cannot make room, publish returns a `:store_full` Store error
and sends no messages. Acknowledge the pending record or delete the durable
subscription to release those records.

For restart durability, implement `Jido.Signal.Bus.Store` and select it at
startup:

```elixir
{:ok, _bus} =
  Bus.start_link(
    name: :my_bus,
    store: MyApp.SignalStore,
    store_opts: [repo: MyApp.Repo]
  )
```

The Store keeps versioned record maps, the latest cursor, and versioned durable
subscription definitions. Its append operation must accept all records or
none. Store startup failure stops Bus startup. The Bus does not silently use
memory storage.

## Telemetry

The Bus emits these events:

- `[:jido, :signal, :bus, :publish]`
- `[:jido, :signal, :bus, :deliver]`
- `[:jido, :signal, :bus, :delivery_error]`
- `[:jido, :signal, :bus, :ack]`
- `[:jido, :signal, :bus, :subscription, :attached]`
- `[:jido, :signal, :bus, :subscription, :detached]`

Delivery events include trace metadata when the Signal has a valid
`Jido.Signal.Trace` value.

## Scoped Buses

Use `jido:` to isolate a Bus name in the package Registry:

```elixir
{:ok, bus} = Bus.start_link(name: :events, jido: TenantA.Jido)
{:ok, ^bus} = Bus.whereis(:events, jido: TenantA.Jido)
```

The scope is a Registry key value. It does not start a process or make a new
Registry.

## Removed v2 Bus Features

v3 removes these Bus features:

- subscription dispatch adapters and multi-target lists;
- middleware and its Task Supervisor;
- `persistent?`, `persistent`, `reconnect/3`, and Signal-ID acknowledgement;
- dead-letter queue inspection and redrive;
- Journal adapters, partitions, and snapshots.

Use `target: pid` for local Bus subscriptions. Use `Jido.Signal.Dispatch`
directly for transport adapters. Start separate Bus processes when workloads
must not block each other.
