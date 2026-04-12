defmodule Jido.Signal.DispatchErrorNormalizationTest do
  use ExUnit.Case, async: false

  alias Jido.Signal
  alias Jido.Signal.Dispatch
  alias Jido.Signal.Error

  # Named function for telemetry handler to avoid performance warnings
  def handle_telemetry_event(event, measurements, metadata, _config) do
    # Get the test pid from the metadata or use a default
    test_pid = Process.get(:test_pid) || self()
    send(test_pid, {:telemetry, event, measurements, metadata})
  end

  # Test with error normalization enabled per test

  test "dispatch normalizes errors to Jido.Signal.Error when enabled" do
    Application.put_env(:jido_signal, :normalize_dispatch_errors, true)
    {:ok, signal} = Signal.new(%{type: "test.event", source: "test", data: %{value: 42}})

    # Use PID adapter with dead process
    {:ok, pid} = Agent.start(fn -> :ok end)
    Agent.stop(pid)

    config = {:pid, [target: pid, delivery_mode: :async]}

    result = Dispatch.dispatch(signal, config)

    assert {:error, %Error.DispatchError{}} = result
    {:error, error} = result

    assert Exception.message(error) =~ "Signal dispatch failed"

    # Clean up
    Application.delete_env(:jido_signal, :normalize_dispatch_errors)
  end

  test "dispatch_batch normalizes errors when enabled" do
    Application.put_env(:jido_signal, :normalize_dispatch_errors, true)
    {:ok, signal} = Signal.new(%{type: "test.event", source: "test", data: %{value: 42}})

    configs = [
      # This should succeed
      {:noop, []},
      # This should fail
      {:named, [target: {:name, :nonexistent_process}, delivery_mode: :async]}
    ]

    result = Dispatch.dispatch_batch(signal, configs, [])

    assert {:error, [{1, %Error.DispatchError{}}]} = result
    {:error, [{1, error}]} = result

    assert Exception.message(error) =~ "Signal dispatch failed"

    # Clean up
    Application.delete_env(:jido_signal, :normalize_dispatch_errors)
  end

  test "telemetry events are emitted with correct metadata" do
    # Set up telemetry handler
    test_pid = self()
    handler_id = :dispatch_test_handler

    # Store the test pid in process dictionary for the handler to access
    Process.put(:test_pid, test_pid)

    :telemetry.attach_many(
      handler_id,
      [
        [:jido, :dispatch, :start],
        [:jido, :dispatch, :stop]
      ],
      &__MODULE__.handle_telemetry_event/4,
      nil
    )

    {:ok, signal} = Signal.new(%{type: "test.event", source: "test", data: %{value: 42}})
    config = {:noop, []}

    # Successful dispatch
    assert :ok = Dispatch.dispatch(signal, config)

    # Should receive start and stop events
    assert_receive {:telemetry, [:jido, :dispatch, :start], %{}, metadata}
    assert metadata.adapter == :noop
    assert metadata.signal_type == "test.event"
    assert metadata.target_kind == :unknown
    assert metadata.runtime_surface == :dispatch

    assert_receive {:telemetry, [:jido, :dispatch, :stop], measurements, metadata}
    assert Map.has_key?(measurements, :duration)
    assert metadata.success? == true
    assert metadata.outcome == :ok

    # Failed dispatch
    {:ok, pid} = Agent.start(fn -> :ok end)
    Agent.stop(pid)
    config = {:pid, [target: pid, delivery_mode: :async]}

    {:error, _} = Dispatch.dispatch(signal, config)

    # Should receive start and stop events with handled error metadata
    assert_receive {:telemetry, [:jido, :dispatch, :start], %{}, _}
    assert_receive {:telemetry, [:jido, :dispatch, :stop], measurements, metadata}
    assert Map.has_key?(measurements, :duration)
    assert metadata.success? == false
    assert metadata.outcome == :error
    assert metadata.error_type == :dispatch_error
    assert metadata.retryable? == false

    :telemetry.detach(handler_id)
  end
end
