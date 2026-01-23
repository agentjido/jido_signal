# Jido Signal Usage Rules

CloudEvents v1.0.2 compliant signal library for Elixir agent systems.

## Signal Creation

```elixir
# Basic signal
# Preferred: positional constructor (type, data, attrs)
{:ok, signal} = Jido.Signal.new("user.created", %{user_id: 123}, source: "/auth/service")

# Also available: Map/keyword constructor (backwards compatible)
{:ok, signal} = Jido.Signal.new(%{
  type: "user.created",
  source: "/auth/service", 
  data: %{user_id: 123}
})

# Custom signal type (preferred)
defmodule UserCreated do
  use Jido.Signal,
    type: "user.created",
    schema: [user_id: [type: :integer, required: true]]
end

{:ok, signal} = UserCreated.new(%{user_id: 123})
```

**Signal Types**: Use dot notation (`"user.created"`, `"payment.processed"`), not camelCase/underscores.

## Dispatch

```elixir
# Direct to PID
:ok = Jido.Signal.Dispatch.dispatch(signal, {:pid, target: pid})

# Multiple destinations
configs = [
  {:pid, target: pid},
  {:logger, level: :info},
  {:http, url: "https://webhook.example.com"}
]
:ok = Jido.Signal.Dispatch.dispatch(signal, configs)
```

**Adapters**: `:pid`, `:pubsub`, `:logger`, `:http`, `:webhook`, `:console`, `:noop`

## Event Bus

```elixir
# Start bus
{:ok, _} = Jido.Signal.Bus.start_link(name: :my_bus)

# Subscribe with patterns
{:ok, sub_id} = Bus.subscribe(:my_bus, "user.*", 
  dispatch: {:pid, target: self()})

# Publish (always as list)
Bus.publish(:my_bus, [signal])
```

**Patterns**: `"user.created"` (exact), `"user.*"` (single), `"user.**"` (multi-level)

## Instance Isolation

For multi-tenant or isolated signal infrastructure:

```elixir
# Start isolated instance
{:ok, _} = Jido.Signal.Instance.start_link(name: MyApp.Jido)

# Bus uses instance-scoped registry
{:ok, _} = Bus.start_link(name: :tenant_bus, jido: MyApp.Jido)

# Lookup uses correct instance
{:ok, pid} = Bus.whereis(:tenant_bus, jido: MyApp.Jido)
```

**Key**: Pass `jido: instance` option to route through instance supervisors.

## Signal Router

High-performance trie-based routing for pattern matching and handler dispatch.

```elixir
# Create router with routes
{:ok, router} = Jido.Signal.Router.new([
  # Exact match
  {"user.created", :handle_user_created},
  
  # Single wildcard (matches one segment)
  {"user.*.updated", :handle_user_update},
  
  # Multi-level wildcard (matches zero or more segments)
  {"audit.**", :audit_logger, 100},  # priority: -100 to 100
  
  # Pattern matching with function
  {"payment.processed",
    fn signal -> signal.data.amount > 1000 end,
    :handle_large_payment,
    90},
  
  # Multiple dispatch targets
  {"system.error", [
    {:logger, [level: :error]},
    {:metrics, [type: :error_count]},
    {:alert, [priority: :high]}
  ]}
])

# Route signal to handlers
{:ok, handlers} = Router.route(router, signal)

# Check if route exists
Router.has_route?(router, "user.created")  # => true

# Check if signal matches pattern
Router.matches?("user.123", "user.*")      # => true

# Filter signals by pattern
filtered = Router.filter(signals, "user.*")

# Dynamic route management
{:ok, router} = Router.add(router, {"metrics.**", :metrics_handler})
{:ok, router} = Router.remove(router, "metrics.**")
```

**Path Patterns**:
- Exact: `"user.created"` (matches exact type)
- Single wildcard: `"user.*"` (matches one segment)
- Multi-level: `"audit.**"` (matches zero or more segments)

**Handler Ordering**: Handlers execute by:
1. **Complexity** (exact > single wildcard > multi-wildcard)
2. **Priority** (-100 to 100, higher first)
3. **Registration order** (FIFO for equal complexity/priority)

**Performance**: Optimized for high-throughput pattern matching:
- O(k) routing where k = number of segments
- Direct segment matching (no trie build per match)
- Efficient multi-wildcard traversal

## Error Handling

```elixir
case Jido.Signal.Dispatch.dispatch(signal, config) do
  :ok -> :success
  {:error, %Jido.Signal.Error.DispatchError{} = error} ->
    Logger.error("Failed: #{error.message}")
end
```

## Anti-Patterns

**❌ Avoid:**
- Generic types: `"event"`, `"message"`
- Bypassing bus: `send(pid, signal)`
- Ignoring errors: `Dispatch.dispatch(signal, config)`

**✅ Use:**
- Specific types: `"user.created"`, `"order.shipped"`
- Bus routing: `Bus.publish(:my_bus, [signal])`
- Error handling: `case Dispatch.dispatch(...) do`

## Advanced Features

### Middleware
```elixir
defmodule MyMiddleware do
  use Jido.Signal.Bus.Middleware
  def before_publish(signals, _ctx, state), do: {:cont, signals, state}
end

Bus.start_link(name: :bus, middleware: [{MyMiddleware, []}])
```

### Persistent Subscriptions
```elixir
{:ok, sub_id} = Bus.subscribe(:bus, "order.*", persistent: true)
:ok = Bus.ack(:bus, sub_id, signal_id)
```

### Journal & Causality
```elixir
journal = Jido.Signal.Journal.new()
{:ok, journal} = Journal.record(journal, signal)
effects = Journal.get_effects(journal, signal.id)
```

### Serialization
```elixir
{:ok, json} = Jido.Signal.Serialization.JsonSerializer.serialize(signal)
{:ok, signal} = Jido.Signal.Serialization.JsonSerializer.deserialize(json)
```

### Snapshots & Replay
```elixir
{:ok, snapshot_ref} = Bus.snapshot_create(:bus, "user.*")
{:ok, signals} = Bus.replay(:bus, "user.*", from_timestamp)
```

## Testing

```elixir
# Create test signal
signal = Jido.Signal.new!("test.event", %{data: "value"})

# Test dispatch
Bus.subscribe(:test_bus, "test.*", dispatch: {:pid, target: self()})
Bus.publish(:test_bus, [signal])
assert_receive {:signal, ^signal}

# Use :noop adapter for testing
dispatch: :noop
```
