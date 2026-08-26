# Event Bus
<!-- covers: jido_signal.guides.event_bus -->

The Event Bus provides ordered, local publish and subscribe delivery. It also
provides middleware hooks, bounded replay, persistent subscriptions, and a
dead-letter queue (DLQ).

## Basic Publish and Subscribe

Start the Bus under your application supervisor:

```elixir
children = [
  {Jido.Signal.Bus, name: :my_bus}
]
```

Subscribe and publish:

```elixir
alias Jido.Signal
alias Jido.Signal.Bus

{:ok, subscription_id} = Bus.subscribe(:my_bus, "user.*")

signal = Signal.new!("user.created", %{user_id: 123}, source: "/users")
{:ok, [recorded]} = Bus.publish(:my_bus, [signal])

receive do
  {:signal, ^signal} -> :ok
end

:ok = Bus.unsubscribe(:my_bus, subscription_id)
```

The default dispatch target is the process that calls `subscribe/3`. You can
set a different target:

```elixir
Bus.subscribe(:my_bus, "user.*",
  dispatch: {:pid, target: subscriber_pid, delivery_mode: :async}
)
```

The Bus checks subscription paths with the Router. It keeps Router precedence:
exact, `*`, `**`, specificity, and then registration order. Dispatch is
synchronous from the Bus process. Use multiple Bus processes when independent
workloads must not block each other.

## Bounded Replay

The default memory store keeps the newest 100,000 records. Set a different
bound with `:max_log_size`:

```elixir
{:ok, _pid} = Bus.start_link(name: :my_bus, max_log_size: 20_000)
```

Replay records by type and Unix timestamp in milliseconds:

```elixir
{:ok, all_records} = Bus.replay(:my_bus, "**")

one_hour_ago = System.system_time(:millisecond) - 3_600_000

{:ok, recent_user_records} =
  Bus.replay(:my_bus, "user.**", one_hour_ago, batch_size: 100)
```

Each `Jido.Signal.Bus.RecordedSignal` has an ID, a numeric cursor, a creation
time, and the Signal.

## Persistent Subscriptions

A persistent subscription uses at-least-once delivery. It keeps a checkpoint
and unacknowledged record IDs. Use `persistent?` as the option name.
`persistent: true` remains a v2 compatibility alias.

```elixir
{:ok, subscription_id} =
  Bus.subscribe(:my_bus, "order.*",
    persistent?: true,
    start_from: :current,
    dispatch: {:pid, target: self()}
  )

{:ok, [_recorded]} = Bus.publish(:my_bus, [order_signal])

receive do
  {:signal, ^order_signal} ->
    process_order(order_signal)
    :ok = Bus.ack(:my_bus, subscription_id, order_signal.id)
end
```

`start_from` accepts these values:

- `:origin` starts at cursor 0. This is the default.
- `:current` starts after the newest retained record.
- A non-negative integer starts after that cursor.

You can acknowledge one ID or a list of IDs. Use a `RecordedSignal.id` when it
is available from `publish/2` or `replay/4`. A live subscriber can use the
delivered `Signal.id`; this keeps the v2 acknowledgement contract. The Bus
advances the checkpoint only across a continuous set of handled records. An
out-of-order acknowledgement does not skip an older unacknowledged record.

When the target process exits, a persistent subscription stays registered. Use
`reconnect/3` with the new process:

```elixir
{:ok, checkpoint} = Bus.reconnect(:my_bus, subscription_id, new_target_pid)
```

The Bus sends retained records after the checkpoint again. A consumer must be
able to handle duplicate delivery.

## Dead-Letter Queue

The Bus does not run an internal retry loop. If dispatch for a persistent
subscription fails, the Bus puts the record in its DLQ and advances the
continuous checkpoint.

```elixir
{:ok, entries} = Bus.dlq_entries(:my_bus, subscription_id)

{:ok, %{succeeded: succeeded, failed: failed}} =
  Bus.redrive_dlq(:my_bus, subscription_id, limit: 100)

:ok = Bus.clear_dlq(:my_bus, subscription_id)
```

Successful redrive removes an entry by default. Set `clear_on_success: false`
to keep it.

## Retained Data Store

The default memory Store state belongs to the Bus process.
Its replay log, checkpoints, and DLQ entries do not survive a Bus restart.

For restart durability, set `:store` to a module that implements
`Jido.Signal.Bus.Store`:

```elixir
{:ok, _pid} =
  Bus.start_link(
    name: :my_bus,
    store: MyApp.SignalStore,
    store_opts: [repo: MyApp.Repo]
  )
```

Store records have `"format_version" => 1`. Custom stores must keep the record
maps unchanged. If store initialization fails, Bus startup fails with
`{:store_init_failed, reason}`. The Bus does not change to memory storage.

The v2 `journal_adapter`, `journal_adapter_opts`, and `journal_pid` options are
removed. They return an `{:unsupported_option, option}` startup error.

## Middleware

Use Bus middleware for small cross-cutting operations:

```elixir
defmodule MyApp.SignalMiddleware do
  use Jido.Signal.Bus.Middleware

  @impl true
  def before_publish(signals, _context, state) do
    {:cont, signals, state}
  end

  @impl true
  def before_dispatch(signal, subscriber, _context, state) do
    if allowed?(signal, subscriber) do
      {:cont, signal, state}
    else
      {:skip, state}
    end
  end

  defp allowed?(_signal, _subscriber), do: true
end

{:ok, _pid} =
  Bus.start_link(
    name: :my_bus,
    middleware: [
      {Jido.Signal.Bus.Middleware.Logger, [level: :info]},
      {MyApp.SignalMiddleware, []}
    ],
    middleware_timeout_ms: 100
  )
```

The callbacks are `before_publish/3`, `after_publish/3`,
`before_dispatch/4`, and `after_dispatch/5`. Each callback has a timeout.

## Instance Isolation

Use `Jido.Signal.Instance` when separate registries are required:

```elixir
alias Jido.Signal.Bus
alias Jido.Signal.Instance

{:ok, _supervisor} = Instance.start_link(name: TenantA.Jido)
{:ok, bus} = Bus.start_link(name: :events, jido: TenantA.Jido)

{:ok, ^bus} = Bus.whereis(:events, jido: TenantA.Jido)
```

Pass the Bus PID to publish and subscribe functions after instance-scoped
lookup.

## Removed v2 Bus Features

v3 removes these Bus features:

- partition workers and partition rate limits;
- snapshots;
- retry waves, backpressure queues, and persistent worker processes;
- Journal adapters and Journal-owned checkpoints.

Use more Bus processes for workload isolation. Keep retry and rate-limit policy
in the calling application. Use `replay/4` for retained reads.

## Next Steps

- [Signal Router](signal-router.md) explains path matching and precedence.
- [Signals and Dispatch](signals-and-dispatch.md) explains delivery targets.
- [Serialization](serialization.md) explains the canonical wire map.
