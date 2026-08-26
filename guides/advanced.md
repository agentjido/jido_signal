# Advanced Usage
<!-- covers: jido_signal.guides.advanced_usage -->

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

Dispatch errors can normalize through `Jido.Signal.Error` when you opt in:

```elixir
# config/config.exs
config :jido_signal,
  default_log_level: :info

# Compatibility transition: normalized dispatch errors remain opt-in.
config :jido_signal,
  normalize_dispatch_errors: true
```

Structured callers can serialize the public contract through `Error.to_map/1`:

```elixir
{:error, error} = Dispatch.dispatch(signal, config)

%{
  type: :dispatch_error,
  message: "Signal dispatch failed",
  details: %{
    "adapter" => "http",
    "reason" => "timeout",
    "target" => %{
      "adapter" => "http",
      "target" => "https://api.example.com/events",
      "target_kind" => "url"
    }
  },
  retryable?: true
} = Jido.Signal.Error.to_map(error)
```

### Multiple Target Error Handling

```elixir
configs = List.duplicate({:http, [url: "http://unreachable"]}, 100)

case Dispatch.dispatch(signal, configs) do
  :ok -> :all_delivered
  {:error, errors} ->
    failed_count = length(errors)
    success_count = length(configs) - failed_count
    Logger.warning("#{failed_count}/#{length(configs)} dispatches failed")
end
```

### Timeout Handling

```elixir
# The caller owns the asynchronous Task and timeout.
task = Task.async(fn -> Dispatch.dispatch(signal, config) end)

case Task.yield(task, 5000) do
  {:ok, :ok} -> :success
  {:ok, {:error, reason}} -> {:dispatch_failed, reason}
  nil -> {:timeout, Task.shutdown(task)}
end
```

### Persistent Subscriptions and DLQ

Persistent subscriptions provide:

- **Continuous checkpoints**: An out-of-order acknowledgement cannot skip an older record.
- **Retained reconnect**: The Bus sends unacknowledged retained records again.
- **Dead Letter Queue**: A failed delivery is kept for inspection and manual redrive.

```elixir
{:ok, sub_id} = Bus.subscribe(:my_bus, "critical.*",
  persistent?: true,
  start_from: :current,
  dispatch: {:pid, target: self()}
)

{:ok, [_recorded]} = Bus.publish(:my_bus, [signal])
:ok = Bus.ack(:my_bus, sub_id, signal.id)
```

See [Event Bus guide](event-bus.md) for DLQ management APIs.

Direct Dispatch does not own circuit breakers. Apply this policy in the calling
application. The Bus also does not run retries or circuit breakers.

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
  assert_receive {[:jido, :dispatch, :stop], %{latency_ms: _},
                  %{outcome: :ok, success?: true}}
end
```

## Performance Considerations

### High-Volume Delivery

Use batching for high-volume dispatch scenarios:

```elixir
# The application owns batching and concurrency.
configs = generate_configs(10_000)
configs
|> Enum.chunk_every(100)
|> Task.async_stream(&Dispatch.dispatch(signal, &1), max_concurrency: 10)
|> Stream.run()
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
    duration_ms = measurements.latency_ms
    adapter = metadata.adapter
    
    if duration_ms > 1000 do
      Logger.warning("Slow dispatch: #{adapter} took #{duration_ms}ms")
    end
  end,
  []
)
```

### High-volume HTTP Delivery

The built-in HTTP adapter uses the OTP `:httpc` profile and has no pool options.
Use a custom Dispatch adapter when the application needs a dedicated connection
pool, custom transport policy, or response processing. The application owns
that adapter and its process life cycle.

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

### Workload Isolation

Start separate Bus processes for workloads that must not block each other. The
calling application owns concurrency and rate-limit policy. v3 does not start
partition workers inside one Bus.

## Next Steps

You've completed the Jido Signal guides! For detailed module documentation, see the [API Reference](https://hexdocs.pm/jido_signal).
