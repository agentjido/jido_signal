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
  def options_schema do
    Zoi.keyword(
      [
        target: Zoi.string() |> Zoi.required(),
        format: Zoi.atom() |> Zoi.required()
      ],
      unrecognized_keys: :error
    )
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

### Durable Subscriptions

Durable subscriptions provide:

- **Stable identity**: A replacement process attaches with the same string ID.
- **One record in flight**: The next record waits for a cursor acknowledgement.
- **At-least-once delivery**: An unacknowledged record is sent again.

```elixir
{:ok, "critical-agent"} =
  Bus.subscribe(:my_bus, "critical.*", durable: "critical-agent")

{:ok, [_published]} = Bus.publish(:my_bus, [signal])

receive do
  {:signal, "critical-agent", recorded} ->
    :ok = handle_signal(recorded.signal)
    :ok = Bus.ack(:my_bus, "critical-agent", recorded.cursor)
end
```

See the [Event Bus guide](event-bus.md) for detach, reattach, and Store rules.

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
    # This fixed module name is safe to use as an instance name.
    instance = __MODULE__.SignalInstance
    {:ok, sup} = Instance.start_link(name: instance)

    on_exit(fn ->
      if Process.alive?(sup), do: Supervisor.stop(sup, :normal, 100)
    end)

    {:ok, instance: instance}
  end

  test "isolated bus operations", %{instance: instance} do
    {:ok, bus} = Bus.start_link(name: :test_bus, jido: instance)
    {:ok, _} = Bus.subscribe(bus, "test.*")
    
    signal = Jido.Signal.new!("test.event", %{value: 42})
    {:ok, _} = Bus.publish(bus, [signal])
    
    assert_receive {:signal, received}
    assert received.data.value == 42
  end
end
```

Do not create instance atoms at runtime. Use a fixed module or atom declared in
application or test code. Runtime atoms remain in the VM atom table.

### Mock Adapters

```elixir
defmodule MockAdapter do
  @behaviour Jido.Signal.Dispatch.Adapter

  def options_schema do
    Zoi.keyword(
      [test_pid: Zoi.pid() |> Zoi.required()],
      unrecognized_keys: :error
    )
  end
  
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

  def options_schema, do: Zoi.keyword([], unrecognized_keys: :error)
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

The built-in adapter accepts only trusted target configuration. It permits
private network targets and does not protect against DNS rebinding. OTP 27
`:httpc` has no response body size limit for these requests. Use a custom
adapter when the target is not trusted or a strict response size limit is
required.

### Bus Subscription Optimization

Use specific Bus paths for high-throughput scenarios:

```elixir
# Use specific patterns instead of wildcards
{:ok, _} = Bus.subscribe(bus, "user.profile.*")

# Batch subscription management
patterns = ["user.created", "user.updated", "user.deleted"]
subscriptions = Enum.map(patterns, fn pattern ->
  Bus.subscribe(bus, pattern)
end)
```

### Workload Isolation

Start separate Bus processes for workloads that must not block each other. The
calling application owns concurrency and rate-limit policy. v3 does not start
partition workers inside one Bus.

## Next Steps

You've completed the Jido Signal guides! For detailed module documentation, see the [API Reference](https://hexdocs.pm/jido_signal).
