# Advanced Usage

```elixir
# Common aliases used in examples
alias Jido.Signal
alias Jido.Signal.Bus
alias Jido.Signal.Dispatch
```

## Custom Adapters

Implement the `Jido.Signal.Dispatch.Adapter` behaviour to create custom signal delivery mechanisms:

```elixir
defmodule MyApp.CustomAdapter do
  @behaviour Jido.Signal.Dispatch.Adapter

  @impl true
  def validate_opts(opts) do
    required = [:target, :format]
    case Enum.find(required, &(!Keyword.has_key?(opts, &1))) do
      nil -> {:ok, opts}
      missing -> {:error, "Missing required option: #{missing}"}
    end
  end

  @impl true
  def deliver(signal, opts) do
    case send_to_target(signal, opts[:target], opts[:format]) do
      :ok -> :ok
      error -> {:error, error}
    end
  end
end
```

Register and use:

```elixir
# Direct usage
config = {MyApp.CustomAdapter, [target: "tcp://localhost:9092", format: :protobuf]}
Jido.Signal.Dispatch.dispatch(signal, config)

# Multiple destinations
configs = [
  {:logger, [level: :info]},
  {MyApp.CustomAdapter, [target: "tcp://localhost:9092", format: :protobuf]}
]
Jido.Signal.Dispatch.dispatch(signal, configs)
```

## Error Handling Strategies

### Normalization

Enable error normalization for structured error handling:

```elixir
# config/config.exs
config :jido, normalize_dispatch_errors: true
```

Without normalization (default):

```elixir
{:error, :timeout} = Dispatch.dispatch(signal, {:http, [url: "http://down.example.com"]})
```

With normalization:

```elixir
{:error, %Jido.Signal.Error.DispatchError{
  message: "Signal dispatch failed",
  details: %{adapter: :http, reason: :timeout, config: {:http, [...]}}
}} = Dispatch.dispatch(signal, config)
```

### Batch Error Handling

```elixir
configs = List.duplicate({:http, [url: "http://unreachable"]}, 100)

case Dispatch.dispatch_batch(signal, configs) do
  :ok -> :all_delivered
  {:error, errors} ->
    # errors is [{index, reason}, ...]
    failed_count = length(errors)
    success_count = length(configs) - failed_count
    Logger.warning("#{failed_count}/#{length(configs)} dispatches failed")
end
```

### Timeout Handling

```elixir
# Async dispatch with timeout
{:ok, task} = Dispatch.dispatch_async(signal, config)

case Task.yield(task, 5000) do
  {:ok, :ok} -> :success
  {:ok, {:error, reason}} -> {:dispatch_failed, reason}
  nil -> {:timeout, Task.shutdown(task)}
end
```

### Persistent Subscriptions, Retries, and DLQ

For reliable message delivery, persistent subscriptions provide:

- **Bounded queues**: `max_in_flight` and `max_pending` prevent unbounded memory growth
- **Automatic retries**: Failed dispatches retry up to `max_attempts` times with `retry_interval` delay
- **Dead Letter Queue**: Exhausted messages are preserved for inspection and reprocessing

```elixir
# Configure for aggressive retry
{:ok, sub_id} = Bus.subscribe(:my_bus, "critical.*",
  persistent?: true,
  dispatch: {:pid, target: self()},
  max_in_flight: 50,
  max_attempts: 10,
  retry_interval: 1000
)

# Configure for fail-fast with DLQ review
{:ok, sub_id} = Bus.subscribe(:my_bus, "batch.*",
  persistent?: true,
  dispatch: {:pid, target: self()},
  max_in_flight: 1000,
  max_attempts: 2,
  retry_interval: 100
)
```

See [Event Bus guide](event-bus.md) for DLQ management APIs.

### Circuit Breaker for External Services

Combine circuit breakers with dispatch for fault isolation:

```elixir
alias Jido.Signal.Dispatch.CircuitBreaker

# Install once at startup
:ok = CircuitBreaker.install(:webhook)

# Use in dispatch
case CircuitBreaker.run(:webhook, fn ->
       Dispatch.dispatch(signal, {:http, [url: webhook_url]})
     end) do
  :ok -> :ok
  {:error, :circuit_open} -> queue_for_later(signal)
  {:error, reason} -> handle_error(reason)
end
```

See [Signals and Dispatch guide](signals-and-dispatch.md) for full circuit breaker documentation.

## Testing Approaches

### Instance Isolation for Tests

Use isolated instances to prevent test interference:

```elixir
defmodule MyApp.SignalTest do
  use ExUnit.Case, async: true

  alias Jido.Signal.Instance
  alias Jido.Signal.Bus

  setup do
    # Create unique instance per test
    instance = :"TestInstance_#{System.unique_integer([:positive])}"
    {:ok, sup} = Instance.start_link(name: instance)

    on_exit(fn ->
      if Process.alive?(sup), do: Supervisor.stop(sup, :normal, 100)
    end)

    {:ok, instance: instance}
  end

  test "isolated bus operations", %{instance: instance} do
    {:ok, bus} = Bus.start_link(name: :test_bus, jido: instance)
    {:ok, _} = Bus.subscribe(bus, "test.*", dispatch: {:pid, target: self()})
    
    signal = Jido.Signal.new!("test.event", %{value: 42})
    {:ok, _} = Bus.publish(bus, [signal])
    
    assert_receive {:signal, received}
    assert received.data.value == 42
  end
end
```

### Mock Adapters

```elixir
defmodule MockAdapter do
  @behaviour Jido.Signal.Dispatch.Adapter

  def validate_opts(opts), do: {:ok, opts}
  
  def deliver(signal, opts) do
    send(opts[:test_pid], {:signal_received, signal, opts})
    :ok
  end
end

# In tests
test "signal delivery" do
  config = {MockAdapter, [test_pid: self()]}
  :ok = Dispatch.dispatch(signal, config)
  
  assert_receive {:signal_received, ^signal, _opts}
end
```

### Testing Error Conditions

```elixir
defmodule FailingAdapter do
  @behaviour Jido.Signal.Dispatch.Adapter
  
  def validate_opts(_), do: {:ok, []}
  def deliver(_, _), do: {:error, :simulated_failure}
end

test "handles adapter failures" do
  config = {FailingAdapter, []}
  assert {:error, _} = Dispatch.dispatch(signal, config)
end
```

### Telemetry Testing

```elixir
test "emits telemetry events" do
  :telemetry_test.attach_event_handlers(self(), [
    [:jido, :dispatch, :start],
    [:jido, :dispatch, :stop]
  ])
  
  Dispatch.dispatch(signal, {:noop, []})
  
  assert_receive {[:jido, :dispatch, :start], _, %{adapter: :noop}}
  assert_receive {[:jido, :dispatch, :stop], %{latency_ms: _}, %{success?: true}}
end
```

## Performance Considerations

### Batch Processing

Use batching for high-volume dispatch scenarios:

```elixir
# Process 10,000 signals in batches of 100 with max 10 concurrent batches
configs = generate_configs(10_000)
Dispatch.dispatch_batch(signal, configs, batch_size: 100, max_concurrency: 10)
```

### Memory Management

For large signal payloads, consider serialization strategies:

```elixir
# Compress large payloads
large_data = generate_large_dataset()
compressed = :zlib.compress(:erlang.term_to_binary(large_data))

signal = Signal.new(%{
  type: "data.compressed",
  source: "/analytics",
  data: compressed,
  datacontenttype: "application/x-erlang-compressed"
})
```

### Telemetry Monitoring

Monitor dispatch performance:

```elixir
:telemetry.attach(
  "dispatch-latency",
  [:jido, :dispatch, :stop],
  fn [:jido, :dispatch, :stop], measurements, metadata, _ ->
    latency = measurements.latency_ms
    adapter = metadata.adapter
    
    if latency > 1000 do
      Logger.warning("Slow dispatch: #{adapter} took #{latency}ms")
    end
  end,
  []
)
```

### Resource Pool Management

For HTTP adapters, configure connection pooling:

```elixir
# Using Finch for HTTP dispatches
config = {:http, [
  url: "https://api.example.com/events",
  method: :post,
  headers: [{"content-type", "application/json"}],
  pool: :analytics_pool,
  pool_timeout: 5000,
  receive_timeout: 30000
]}
```

### Bus Subscription Optimization

Optimize bus subscriptions for high-throughput scenarios:

```elixir
# Use specific patterns instead of wildcards
{:ok, _} = Bus.subscribe(bus, "user.profile.*",
  dispatch: {:pid, target: self(), delivery_mode: :async}
)  # Better

# Batch subscription management
patterns = ["user.created", "user.updated", "user.deleted"]
subscriptions = Enum.map(patterns, fn pattern ->
  Bus.subscribe(bus, pattern, dispatch: {:pid, target: self(), delivery_mode: :async})
end)
```

### Horizontal Scaling with Partitions

For high-throughput scenarios, enable partitioned dispatch:

```elixir
{:ok, _pid} = Bus.start_link(
  name: :high_volume_bus,
  partition_count: System.schedulers_online(),
  partition_rate_limit_per_sec: 50_000,
  partition_burst_size: 5_000
)
```

Partitions distribute non-persistent subscriptions across workers, each with independent rate limiting. Monitor partition health via telemetry:

- `[:jido, :signal, :bus, :rate_limited]` - Partition dropping signals due to rate limit

## Next Steps

You've completed the Jido Signal guides! For detailed module documentation, see the [API Reference](https://hexdocs.pm/jido_signal).
