# Advanced Usage
<!-- covers: jido_signal.guides.advanced_usage -->

Use this guide for custom adapters, error handling, tests, and application-owned
execution policy. Examples use these aliases:

```elixir
alias Jido.Signal
alias Jido.Signal.Bus
alias Jido.Signal.Dispatch
```

## Custom Adapters

A custom adapter provides `options_schema/0` and `deliver/2`. Dispatch validates
options before delivery. Return `:ok` or `{:error, reason}` from `deliver/2`.
A raised, thrown, or exited callback fault propagates to the caller after
exception telemetry is emitted.

This complete adapter sends a Signal in an application-specific message:

```elixir
defmodule MyApp.CustomAdapter do
  @behaviour Jido.Signal.Dispatch.Adapter

  @impl true
  def options_schema do
    Zoi.keyword(
      [target: Zoi.pid() |> Zoi.required()],
      unrecognized_keys: :error
    )
  end

  @impl true
  def deliver(signal, opts) do
    send(Keyword.fetch!(opts, :target), {:app_event, signal})
    :ok
  end
end

signal = Signal.new!("user.created", %{"user_id" => "123"}, source: "/users")
:ok = Dispatch.dispatch(signal, {MyApp.CustomAdapter, target: self()})

receive do
  {:app_event, ^signal} -> :ok
end
```

No registration step is required. Supply the adapter module in the target tuple.
The adapter owns its transport-specific success rules. The example confirms a
send operation; it does not confirm consumer processing.

## Error Handling

A single target returns `:ok` or `{:error, reason}`. A target list collects
returned errors in target order. Adapter faults that raise, throw, or exit stop
the call instead of becoming list entries.

```elixir
configs = [
  {:logger, level: :info},
  {MyApp.CustomAdapter, target: self()}
]

case Dispatch.dispatch(signal, configs) do
  :ok -> :all_delivered
  {:error, errors} -> {:delivery_failures, errors}
end
```

Enable structured errors in application configuration:

```elixir
config :jido_signal, normalize_dispatch_errors: true
```

Delivery errors use `Jido.Signal.Error.DispatchError`. Configuration errors use
`Jido.Signal.Error.InvalidInputError`. Use `Jido.Signal.Error.to_map/1` for the
public error map, which includes sanitized details and a `retryable?` value:

```elixir
case Dispatch.dispatch(signal, config) do
  :ok -> :delivered
  {:error, error} -> {:delivery_error, Jido.Signal.Error.to_map(error)}
end
```

This example assumes one target and structured errors enabled. For a target
list, convert each returned error separately. `retryable?` is a classification;
Dispatch does not schedule a retry.

## Caller-Owned Tasks and Timeouts

The application owns asynchronous execution and its failure policy. For example,
a Task can run Dispatch while the caller sets a wait limit:

```elixir
task = Task.async(fn -> Dispatch.dispatch(signal, config) end)

case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
  {:ok, :ok} -> :success
  {:ok, {:error, reason}} -> {:dispatch_failed, reason}
  {:exit, reason} -> {:task_failed, reason}
  nil -> :timeout
end
```

`Task.async/1` links the Task to its caller. A callback fault can terminate that
caller. Use an application-owned Task supervisor and
`Task.Supervisor.async_nolink/2` when the caller must handle Task failures
without a link. Stopping a Task does not undo a delivery that already occurred.

For concurrent delivery, inspect each result from `Task.async_stream/3`.
Do not discard the stream results if delivery failures matter. Retry,
concurrency limits, circuit breakers, and workload isolation belong to the
application.

## Durable Consumers

Use a durable Bus subscription when a replacement consumer must receive an
unacknowledged record. Process the record before acknowledging its cursor.
Handlers must tolerate duplicate delivery. The default memory Store survives
consumer replacement while the Bus stays alive; it does not survive a Bus or
VM restart.

See [Durable Subscriptions](event-bus.md#durable-subscriptions) and
[Store Boundary](event-bus.md#store-boundary) for setup and recovery rules.

## Tests

### Supervise Test Buses

Use `start_supervised!/1` so ExUnit stops the Bus after the test. A scope is
Registry key data; it needs no separate process. Use different names or scopes
for Buses that can run at the same time.

```elixir
defmodule MyApp.SignalTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus

  test "isolated bus delivery" do
    bus = start_supervised!({Bus, name: :test_bus, jido: __MODULE__})
    {:ok, _subscription} = Bus.subscribe(bus, "test.*")
    signal = Signal.new!("test.event", %{"value" => 42}, source: "/test")

    {:ok, [_recorded]} = Bus.publish(bus, [signal])
    assert_receive {:signal, ^signal}
  end
end
```

### Check Adapter Results

The custom adapter above can act as a test adapter. Supply `target: self()` and
assert receipt of `{:app_event, signal}`. To test returned failures, use a
separate adapter:

```elixir
defmodule MyApp.FailingAdapter do
  @behaviour Jido.Signal.Dispatch.Adapter

  @impl true
  def options_schema, do: Zoi.keyword([], unrecognized_keys: :error)

  @impl true
  def deliver(_signal, _opts), do: {:error, :simulated_failure}
end
```

With error normalization disabled, dispatch to this adapter returns
`{:error, :simulated_failure}`. With normalization enabled, it returns a
structured Dispatch error.

### Check Telemetry

The telemetry test helper sends `{event, reference, measurements, metadata}`.
Detach the handler after each test:

```elixir
defmodule MyApp.DispatchTelemetryTest do
  use ExUnit.Case, async: true

  test "emits start and stop events" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:jido, :dispatch, :start],
        [:jido, :dispatch, :stop]
      ])

    on_exit(fn -> :telemetry.detach(ref) end)

    signal = Jido.Signal.new!("test.event", nil, source: "/test")
    :ok = Jido.Signal.Dispatch.dispatch(signal, {:noop, []})

    assert_receive {[:jido, :dispatch, :start], ^ref, %{}, %{adapter: :noop}}

    assert_receive {[:jido, :dispatch, :stop], ^ref, %{latency_ms: _},
                    %{outcome: :ok, success?: true}}
  end
end
```

Dispatch emits `:exception` instead of `:stop` when a delivery callback raises,
throws, or exits. These events measure the adapter call, not downstream consumer
processing. Avoid assertions about exact durations.

For generated boundary and lifecycle tests, see
[Property and Fuzz Tests](property-testing.md).

## HTTP Transport Policy

The built-in HTTP adapter uses OTP `:httpc`. It has no custom pool options and
accepts only `url`, `headers`, and `timeout`. Use JSON-safe Signal data. Use a
custom adapter for connection pools, request signing, response processing, or
other transport policy. See [HTTP Adapter](signals-and-dispatch.md#http-adapter)
for target and response limits.

## Payload and Workload Limits

Serialization has an encoded-byte limit. It does not bound the memory used to
construct or encode a large value. Keep payloads within application limits, or
store large data externally and carry a reference in the Signal.

Start separate Bus processes for workloads that must not block each other. One
Bus processes publication and Store operations sequentially. A slow custom Store
can delay other calls to that Bus.

Use specific subscription paths to reduce matching candidates. Source and
subject selectors can narrow live delivery without inspecting domain data.
Measure the effect with the [benchmark suite](benchmarks.md) before making a
performance claim.
