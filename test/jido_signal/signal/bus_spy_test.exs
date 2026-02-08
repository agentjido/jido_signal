defmodule Jido.Signal.BusSpyTest do
  # async: false because BusSpy is a global telemetry listener
  # that captures events from all buses
  use ExUnit.Case, async: false

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias Jido.Signal.BusSpy

  setup do
    # Generate unique bus name for this test
    bus_name = :"test_bus_spy_#{System.unique_integer([:positive])}"

    # Start a test bus
    {:ok, _bus_pid} = Bus.start_link(name: bus_name)

    on_exit(fn ->
      case Bus.whereis(bus_name) do
        {:ok, pid} when is_pid(pid) ->
          if Process.alive?(pid) do
            try do
              GenServer.stop(pid, :normal, 1000)
            catch
              :exit, _ -> :ok
            end
          end

        _ ->
          :ok
      end
    end)

    {:ok, bus_name: bus_name}
  end

  test "spy captures signals crossing bus boundaries", %{bus_name: bus_name} do
    # Start the spy
    spy = BusSpy.start_spy()

    # Subscribe to test events
    {:ok, _sub_id} = Bus.subscribe(bus_name, "test.*", [])

    # Create and publish a test signal
    {:ok, signal} =
      Signal.new(%{
        type: "test.event",
        source: "test_source",
        data: %{message: "hello world"}
      })

    {:ok, _recorded} = Bus.publish(bus_name, [signal])

    wait_until(fn -> BusSpy.get_signals_by_type(spy, "test.event") != [] end)

    # Check that the spy captured the signal
    dispatched_signals = BusSpy.get_dispatched_signals(spy)
    assert dispatched_signals != []

    # Find our test event
    test_events = BusSpy.get_signals_by_type(spy, "test.event")
    assert test_events != []

    # Get the first event (before_dispatch)
    event = hd(test_events)
    assert event.event == :before_dispatch
    assert event.bus_name == bus_name
    assert event.signal_type == "test.event"
    assert event.signal.data.message == "hello world"

    BusSpy.stop_spy(spy)
  end

  test "spy can wait for specific signals", %{bus_name: bus_name} do
    spy = BusSpy.start_spy()

    # Subscribe to test events
    {:ok, _sub_id} = Bus.subscribe(bus_name, "async.*", [])

    # Start a task to publish signal after delay
    Task.start(fn ->
      {:ok, signal} =
        Signal.new(%{
          type: "async.test",
          source: "delayed_source",
          data: %{delayed: true}
        })

      Bus.publish(bus_name, [signal])
    end)

    # Wait for the signal to arrive
    assert {:ok, event} = BusSpy.wait_for_signal(spy, "async.test", 1000)
    assert event.signal.data.delayed == true

    BusSpy.stop_spy(spy)
  end

  test "spy pattern matching works correctly", %{bus_name: bus_name} do
    spy = BusSpy.start_spy()

    # Subscribe to user and order events
    {:ok, _user_sub} = Bus.subscribe(bus_name, "user.*", [])
    {:ok, _order_sub} = Bus.subscribe(bus_name, "order.*", [])

    # Publish various signals
    signals = [
      %{type: "user.created", source: "auth", data: %{id: 1}},
      %{type: "user.updated", source: "auth", data: %{id: 1}},
      %{type: "order.placed", source: "shop", data: %{id: 2}},
      %{type: "order.cancelled", source: "shop", data: %{id: 2}}
    ]

    for signal_data <- signals do
      {:ok, signal} = Signal.new(signal_data)
      Bus.publish(bus_name, [signal])
    end

    wait_until(fn -> length(BusSpy.get_dispatched_signals(spy)) >= 4 end)

    # Test different pattern matches
    user_events = BusSpy.get_signals_by_type(spy, "user.*")

    # At least before_dispatch events
    assert length(user_events) >= 2

    order_events = BusSpy.get_signals_by_type(spy, "order.*")
    # At least before_dispatch events
    assert length(order_events) >= 2

    all_events = BusSpy.get_dispatched_signals(spy)
    # At least 4 events (4 signals, each with before_dispatch)
    assert length(all_events) >= 4

    exact_match = BusSpy.get_signals_by_type(spy, "user.created")
    assert exact_match != []
    assert hd(exact_match).signal.type == "user.created"

    BusSpy.stop_spy(spy)
  end

  test "spy captures dispatch results and errors", %{bus_name: bus_name} do
    spy = BusSpy.start_spy()

    # Subscribe with a pid dispatch to self()
    {:ok, _sub_id} =
      Bus.subscribe(bus_name, "result.*",
        dispatch: {:pid, [target: self(), delivery_mode: :async]}
      )

    # Create test signal
    {:ok, signal} =
      Signal.new(%{
        type: "result.test",
        source: "test",
        data: %{test: true}
      })

    {:ok, _recorded} = Bus.publish(bus_name, [signal])

    wait_until(fn ->
      BusSpy.get_dispatched_signals(spy)
      |> Enum.any?(&(&1.event == :after_dispatch))
    end)

    # Check for after_dispatch events with results
    dispatched_signals = BusSpy.get_dispatched_signals(spy)
    after_dispatch_events = Enum.filter(dispatched_signals, &(&1.event == :after_dispatch))

    assert after_dispatch_events != []
    event = hd(after_dispatch_events)
    assert event.dispatch_result == :ok

    BusSpy.stop_spy(spy)
  end

  test "spy clears events correctly", %{bus_name: bus_name} do
    spy = BusSpy.start_spy()

    {:ok, _sub_id} = Bus.subscribe(bus_name, "clear.*", [])

    {:ok, signal} =
      Signal.new(%{
        type: "clear.test",
        source: "test",
        data: %{}
      })

    Bus.publish(bus_name, [signal])
    wait_until(fn -> not Enum.empty?(BusSpy.get_dispatched_signals(spy)) end)

    # Verify events exist
    events = BusSpy.get_dispatched_signals(spy)
    refute Enum.empty?(events)

    # Clear events
    :ok = BusSpy.clear_events(spy)

    # Verify events are cleared
    events = BusSpy.get_dispatched_signals(spy)
    assert events == []

    BusSpy.stop_spy(spy)
  end

  test "waiter timer is canceled when a waiter is satisfied" do
    spy = BusSpy.start_spy()

    waiter_task =
      Task.async(fn ->
        BusSpy.wait_for_signal(spy, "timer.cancel", 5_000)
      end)

    waiter = wait_for_registered_waiter(spy)
    timer_ref = Map.fetch!(waiter, :timer_ref)
    assert is_reference(timer_ref)

    {:ok, signal} =
      Signal.new(%{
        type: "timer.cancel",
        source: "test",
        data: %{value: 1}
      })

    send(
      spy,
      {:telemetry_event, [:jido, :signal, :bus, :before_dispatch],
       %{timestamp: System.monotonic_time(:microsecond)},
       %{
         bus_name: :timer_cancel_bus,
         signal_id: signal.id,
         signal_type: signal.type,
         subscription_id: "timer-subscription",
         subscription_path: "timer.cancel",
         signal: signal,
         subscription: %{},
         dispatch_result: nil,
         error: nil,
         reason: nil
       }}
    )

    assert {:ok, event} = Task.await(waiter_task, 1_000)
    assert event.signal_type == "timer.cancel"
    assert [] = :sys.get_state(spy).waiters
    assert :erlang.read_timer(timer_ref) == false

    BusSpy.stop_spy(spy)
  end

  defp wait_for_registered_waiter(spy, attempts \\ 500)

  defp wait_for_registered_waiter(_spy, 0), do: flunk("waiter was not registered")

  defp wait_for_registered_waiter(spy, attempts) do
    case :sys.get_state(spy).waiters do
      [waiter | _] ->
        waiter

      [] ->
        receive do
        after
          0 -> wait_for_registered_waiter(spy, attempts - 1)
        end
    end
  end

  defp wait_until(fun, attempts \\ 500)
  defp wait_until(_fun, 0), do: flunk("condition not met in wait_until/2")

  defp wait_until(fun, attempts) when is_function(fun, 0) do
    if fun.() do
      :ok
    else
      receive do
      after
        0 -> wait_until(fun, attempts - 1)
      end
    end
  end
end
