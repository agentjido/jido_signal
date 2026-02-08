defmodule Jido.Signal.Bus.NonBlockingCallbacksTest do
  use ExUnit.Case, async: false

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias Jido.Signal.Dispatch

  @moduletag :capture_log

  defmodule BlockingDispatchAdapter do
    @behaviour Dispatch.Adapter

    @impl true
    def validate_opts(opts), do: {:ok, opts}

    @impl true
    def deliver(signal, opts) do
      if Map.get(signal.data, :block?, false) do
        test_pid = Keyword.fetch!(opts, :test_pid)
        signal_id = signal.id
        send(test_pid, {:dispatch_started, self(), signal_id})

        receive do
          {:release_dispatch, ^signal_id} -> :ok
        end
      else
        :ok
      end
    end
  end

  test "publish returns before a persistent subscription finishes blocking downstream dispatch" do
    bus_name = :"non_blocking_publish_#{System.unique_integer([:positive])}"
    start_supervised!({Bus, name: bus_name})

    {:ok, _subscription_id} =
      Bus.subscribe(bus_name, "test.blocking",
        persistent?: true,
        max_in_flight: 1,
        max_pending: 10,
        dispatch: {BlockingDispatchAdapter, [test_pid: self()]}
      )

    signal = Signal.new!(type: "test.blocking", source: "/test", data: %{value: 1, block?: true})
    signal_id = signal.id
    parent = self()

    spawn(fn ->
      send(parent, {:publish_result, Bus.publish(bus_name, [signal])})
    end)

    assert_receive {:dispatch_started, dispatch_pid, ^signal_id}, 1_000

    try do
      assert_receive {:publish_result, {:ok, [_recorded_signal]}}, 200
    after
      send(dispatch_pid, {:release_dispatch, signal_id})
    end
  end

  test "ack returns before processing pending blocking dispatch work" do
    bus_name = :"non_blocking_ack_#{System.unique_integer([:positive])}"
    start_supervised!({Bus, name: bus_name})

    {:ok, subscription_id} =
      Bus.subscribe(bus_name, "test.ack",
        persistent?: true,
        max_in_flight: 1,
        max_pending: 10,
        dispatch: {BlockingDispatchAdapter, [test_pid: self()]}
      )

    first_signal = Signal.new!(type: "test.ack", source: "/test", data: %{value: 1})
    {:ok, [first_recorded]} = Bus.publish(bus_name, [first_signal])

    second_signal =
      Signal.new!(type: "test.ack", source: "/test", data: %{value: 2, block?: true})

    second_signal_id = second_signal.id
    {:ok, [_second_recorded]} = Bus.publish(bus_name, [second_signal])

    parent = self()

    spawn(fn ->
      send(parent, {:ack_result, Bus.ack(bus_name, subscription_id, first_recorded.id)})
    end)

    assert_receive {:dispatch_started, dispatch_pid, ^second_signal_id}, 1_000

    try do
      assert_receive {:ack_result, :ok}, 200
    after
      send(dispatch_pid, {:release_dispatch, second_signal_id})
    end
  end
end
