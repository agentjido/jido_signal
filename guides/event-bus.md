# Event Bus

The Event Bus provides publish/subscribe messaging with middleware hooks, persistent subscriptions, and snapshot functionality.

## Basic Publish/Subscribe

Start a bus and publish signals:

```elixir
# Start the bus
{:ok, _pid} = Jido.Signal.Bus.start_link(name: :my_bus)

# Create and publish signals
signal = Jido.Signal.new!("user.created", %{user_id: 123})
{:ok, _recorded} = Jido.Signal.Bus.publish(:my_bus, [signal])

# Subscribe to signal patterns
{:ok, sub_id} = Jido.Signal.Bus.subscribe(:my_bus, "user.*")

# Subscribe with specific dispatch
{:ok, sub_id} = Jido.Signal.Bus.subscribe(:my_bus, "user.*", 
  dispatch: {:pid, target: self(), delivery_mode: :async}
)
```

Unsubscribe:

```elixir
:ok = Jido.Signal.Bus.unsubscribe(:my_bus, sub_id)
```

## Error Handling

All Bus functions return `{:ok, result}` on success or `{:error, term()}` on failure:

```elixir
case Jido.Signal.Bus.publish(:my_bus, [signal]) do
  {:ok, recorded_signals} -> 
    Logger.info("Published #{length(recorded_signals)} signals")
  {:error, reason} -> 
    Logger.error("Publish failed: #{inspect(reason)}")
end

case Jido.Signal.Bus.subscribe(:my_bus, "user.*") do
  {:ok, sub_id} -> sub_id
  {:error, :bus_not_found} -> raise "Bus not running"
  {:error, reason} -> raise "Subscribe failed: #{inspect(reason)}"
end
```

## Middleware Hooks

Implement custom middleware to intercept signals:

```elixir
defmodule MyMiddleware do
  use Jido.Signal.Bus.Middleware

  @impl true
  def init(opts), do: {:ok, %{}}

  @impl true
  def before_publish(signals, context, state) do
    # Transform or validate signals before publishing
    {:cont, signals, state}
  end

  @impl true
  def before_dispatch(signal, subscriber, context, state) do
    # Filter or modify signal before dispatch to subscriber
    if authorized?(signal, subscriber) do
      {:cont, signal, state}
    else
      {:skip, state}  # Skip this subscriber
    end
  end

  @impl true
  def after_dispatch(signal, subscriber, result, context, state) do
    # Log or handle dispatch results
    {:cont, state}
  end

  defp authorized?(signal, subscriber), do: true
end
```

Start bus with middleware:

```elixir
{:ok, _pid} = Jido.Signal.Bus.start_link(
  name: :my_bus,
  middleware: [{MyMiddleware, []}]
)
```

Middleware callbacks are executed by `Jido.Signal.Bus.MiddlewarePipeline` with per-callback timeouts (`middleware_timeout_ms`, default 100ms). Each callback can:
- `{:cont, ...}` - Continue processing
- `{:skip, state}` - Skip this subscriber (for `before_dispatch` only)
- `{:halt, reason, state}` - Stop processing and fail the operation

## Persistent Subscriptions

Persistent subscriptions provide reliable message delivery with acknowledgments, checkpointing, and automatic retry with Dead Letter Queue (DLQ) support.

```elixir
# Create persistent subscription with reliability options
{:ok, sub_id} = Jido.Signal.Bus.subscribe(:my_bus, "order.*",
  persistent: true,
  dispatch: {:pid, target: self(), delivery_mode: :async},
  max_in_flight: 500,      # Max unacknowledged signals (default: 1000)
  max_pending: 5_000,      # Max queued signals before backpressure (default: 10_000)
  max_attempts: 5,         # Retry attempts before moving to DLQ (default: 5)
  retry_interval: 500      # Milliseconds between retry waves (default: 100)
)

# Acknowledge processed signals
:ok = Jido.Signal.Bus.ack(:my_bus, sub_id, signal_id)

# Batch acknowledgment
:ok = Jido.Signal.Bus.ack(:my_bus, sub_id, [signal_id_1, signal_id_2, signal_id_3])

# Reconnect after client disconnect (subscription survives)
{:ok, last_checkpoint} = Jido.Signal.Bus.reconnect(:my_bus, sub_id, self())
```

Persistent subscriptions require a journal adapter to persist checkpoints across restarts:

```elixir
{:ok, _pid} = Jido.Signal.Bus.start_link(
  name: :my_bus,
  journal_adapter: Jido.Signal.Journal.Adapters.ETS
)
```

When configured, checkpoints are automatically persisted and restored on reconnection.

## Dead Letter Queue (DLQ)

When a persistent subscription exhausts all retry attempts (`max_attempts`), failed signals are moved to the Dead Letter Queue for later inspection and reprocessing.

```elixir
# List DLQ entries for a subscription
{:ok, entries} = Jido.Signal.Bus.get_dlq_entries(:my_bus, sub_id)
# Each entry: %{id, subscription_id, signal, reason, metadata, inserted_at}

# Redrive (re-dispatch) DLQ messages
{:ok, %{succeeded: count, failed: failures}} = 
  Jido.Signal.Bus.redrive_dlq(:my_bus, sub_id, limit: 100)

# Clear all DLQ entries for a subscription
:ok = Jido.Signal.Bus.clear_dlq(:my_bus, sub_id)
```

DLQ requires a journal adapter that implements the DLQ callbacks. Both ETS and Mnesia adapters support DLQ out of the box.

## Horizontal Scaling with Partitions

For high-throughput scenarios, the bus can distribute dispatch across multiple partition workers:

```elixir
{:ok, _pid} = Jido.Signal.Bus.start_link(
  name: :my_bus,
  partition_count: 4,                    # Number of partition workers
  partition_rate_limit_per_sec: 10_000,  # Rate limit per partition
  partition_burst_size: 1_000,           # Token bucket burst size
  middleware: [
    {Jido.Signal.Bus.Middleware.Logger, [level: :info]}
  ],
  journal_adapter: Jido.Signal.Journal.Adapters.ETS
)
```

With partitions enabled:
- Non-persistent subscriptions are sharded across partitions based on subscription ID
- Each partition has independent rate limiting using a token bucket algorithm
- Persistent subscriptions are handled by the main bus process to honor backpressure
- Rate-limited signals emit telemetry: `[:jido, :signal, :bus, :rate_limited]`

## Snapshots and Replay

Create snapshots of signal history:

```elixir
# Create snapshot of all user events
{:ok, snapshot_ref} = Jido.Signal.Bus.snapshot_create(:my_bus, "user.*")

# Read snapshot data
{:ok, snapshot_data} = Jido.Signal.Bus.snapshot_read(:my_bus, snapshot_ref.id)

# List all snapshots
snapshots = Jido.Signal.Bus.snapshot_list(:my_bus)

# Delete snapshot
:ok = Jido.Signal.Bus.snapshot_delete(:my_bus, snapshot_ref.id)
```

Replay signals from specific timestamp:

```elixir
# Replay all signals from timestamp
{:ok, signals} = Jido.Signal.Bus.replay(:my_bus, "*", timestamp)

# Replay specific signal types
{:ok, user_signals} = Jido.Signal.Bus.replay(:my_bus, "user.*", timestamp)
```

## Instance Isolation

For multi-tenant applications or isolated testing, create instance-scoped signal infrastructure:

```elixir
alias Jido.Signal.Instance
alias Jido.Signal.Bus

# Start an isolated instance (starts its own Registry, TaskSupervisor, Ext.Registry)
{:ok, _} = Instance.start_link(name: MyApp.Jido)

# Start bus scoped to the instance
{:ok, _} = Bus.start_link(name: :tenant_bus, jido: MyApp.Jido)

# Lookup uses the instance's registry
{:ok, bus_pid} = Bus.whereis(:tenant_bus, jido: MyApp.Jido)

# Check if instance is running
Instance.running?(MyApp.Jido)  # => true

# Stop instance and all its children
Instance.stop(MyApp.Jido)
```

### Multi-Tenant Isolation

Multiple instances are completely isolated from each other:

```elixir
# Start separate instances for each tenant
{:ok, _} = Instance.start_link(name: TenantA.Jido)
{:ok, _} = Instance.start_link(name: TenantB.Jido)

# Same bus name, different instances = different processes
{:ok, bus_a} = Bus.start_link(name: :events, jido: TenantA.Jido)
{:ok, bus_b} = Bus.start_link(name: :events, jido: TenantB.Jido)

# Completely isolated - signals don't cross instances
Bus.subscribe(bus_a, "order.*", dispatch: {:pid, target: tenant_a_handler})
Bus.subscribe(bus_b, "order.*", dispatch: {:pid, target: tenant_b_handler})

# Publish to tenant A only
Bus.publish(bus_a, [order_signal])  # Only tenant_a_handler receives
```

### Process Name Resolution

The `jido:` option controls which registry is used for process lookup:

```elixir
# Global (default) - uses Jido.Signal.Registry
Bus.start_link(name: :my_bus)

# Instance-scoped - uses MyApp.Jido.Signal.Registry
Bus.start_link(name: :my_bus, jido: MyApp.Jido)
```

Use `Jido.Signal.Names` to resolve process names programmatically:

```elixir
alias Jido.Signal.Names

Names.registry([])                    # => Jido.Signal.Registry
Names.registry(jido: MyApp.Jido)      # => MyApp.Jido.Signal.Registry
Names.task_supervisor(jido: MyApp.Jido)  # => MyApp.Jido.Signal.TaskSupervisor
```

## Advanced Configuration

Configure bus with custom router and options:

```elixir
custom_router = Jido.Signal.Router.new!()

{:ok, _pid} = Jido.Signal.Bus.start_link(
  name: :my_bus,
  router: custom_router,
  middleware: [
    {Jido.Signal.Bus.Middleware.Logger, []},
    {MyCustomMiddleware, [option: :value]}
  ]
)
```

Persistent subscription options:

```elixir
{:ok, sub_id} = Jido.Signal.Bus.subscribe(:my_bus, "events.*",
  persistent: true,
  dispatch: {:pid, target: self(), delivery_mode: :async},
  max_in_flight: 100,    # Max unacknowledged signals
  max_pending: 5_000,    # Max pending before backpressure
  max_attempts: 5,       # Attempts before DLQ
  retry_interval: 500,   # Retry interval in ms
  start_from: :origin    # :origin, :current, or timestamp
)
```

## Next Steps

- [Signal Router](signal-router.md) - Trie-based routing with pattern matching and priority execution
- [Signal Extensions](signal-extensions.md) - Add domain-specific metadata while maintaining CloudEvents compliance
