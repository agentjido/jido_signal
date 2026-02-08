defmodule JidoTest.Signal.Bus.PersistentSubscriptionTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias Jido.Signal.Bus.PersistentSubscription
  alias Jido.Signal.Bus.Subscriber
  alias Jido.Signal.ID

  require Logger

  # Uncomment to see detailed logs during test execution
  # @moduletag :capture_log

  describe "persistent subscription" do
    setup do
      bus_name = :"bus_#{System.unique_integer()}"
      bus_pid = start_supervised!({Bus, name: bus_name})
      test_pid = self()

      {:ok, bus_pid: bus_pid, test_pid: test_pid}
    end

    test "starts a persistent subscription", %{bus_pid: bus_pid, test_pid: test_pid} do
      opts = [
        bus_pid: bus_pid,
        path: "test/path",
        client_pid: test_pid,
        bus_subscription: %{dispatch: []}
      ]

      {:ok, pid} = PersistentSubscription.start_link(opts)
      assert Process.alive?(pid)
    end

    # @tag :skip
    # test "accepts signal and forwards to subscriber", %{bus_pid: bus_pid, test_pid: test_pid} do
    #   # First verify that direct dispatch works correctly
    #   direct_dispatch_config = [{:pid, [target: test_pid]}]
    #   test_signal = Signal.new!(%{type: "direct-test", source: "/test", data: %{test: "direct"}})

    #   # This should send a message directly to our test process
    #   :ok = Jido.Signal.Dispatch.dispatch(test_signal, direct_dispatch_config)

    #   # Verify we received the direct test signal
    #   assert_receive {:signal, direct_signal}, 500
    #   assert direct_signal.type == "direct-test"
    #   assert direct_signal.data == %{test: "direct"}

    #   # Now set up the persistent subscription with the correct dispatch format
    #   dispatch_config = [{:pid, [target: test_pid]}]

    #   opts = [
    #     bus_pid: bus_pid,
    #     path: "test/path",
    #     client_pid: test_pid,
    #     bus_subscription: %Subscriber{
    #       id: ID.generate!(),
    #       path: "test/path",
    #       dispatch: dispatch_config
    #     }
    #   ]

    #   # Start the persistent subscription
    #   {:ok, persistent_pid} = PersistentSubscription.start_link(opts)

    #   # Create a test signal to send through the subscription
    #   signal =
    #     Signal.new!(%{
    #       type: "test-type",
    #       source: "/test",
    #       data: %{test: "data"}
    #     })

    #   # Generate a UUID7 for the signal log ID
    #   signal_log_id = ID.generate!()

    #   # Send signal to subscription process
    #   send(persistent_pid, {:signal, {signal_log_id, signal}})

    #   # The subscription should dispatch the signal to our test process
    #   # We should receive it wrapped in a {:signal, signal} tuple
    #   assert_eventually(
    #     fn ->
    #       receive do
    #         {:signal, received_signal} ->
    #           received_signal.type == signal.type and received_signal.data == signal.data
    #       after
    #         0 -> false
    #       end
    #     end,
    #     timeout: 1000
    #   )

    #   # Verify the signal is tracked in the subscription's in-flight map
    #   state = :sys.get_state(persistent_pid)
    #   assert map_size(state.in_flight_signals) == 1
    #   assert Map.has_key?(state.in_flight_signals, signal_log_id)
    # end

    test "handles signal acknowledgment", %{bus_pid: bus_pid, test_pid: test_pid} do
      # Set up the persistent subscription with max_in_flight=1 to test queuing
      dispatch_config = [{:pid, [target: test_pid]}]

      opts = [
        bus_pid: bus_pid,
        path: "test/path",
        client_pid: test_pid,
        # Only allow 1 in-flight signal at a time
        max_in_flight: 1,
        bus_subscription: %Subscriber{
          id: ID.generate!(),
          path: "test/path",
          dispatch: dispatch_config
        }
      ]

      {:ok, pid} = PersistentSubscription.start_link(opts)

      # Create two test signals
      signal1 =
        Signal.new!(%{
          type: "test-type-1",
          source: "/test",
          data: %{test: "data1"}
        })

      signal2 =
        Signal.new!(%{
          type: "test-type-2",
          source: "/test",
          data: %{test: "data2"}
        })

      # Generate UUID7s for signal log IDs
      signal_log_id1 = ID.generate!()
      signal_log_id2 = ID.generate!()

      # Send first signal
      send(pid, {:signal, {signal_log_id1, signal1}})

      # We should receive the first signal
      assert_receive {:signal, received_signal1}, 500
      assert received_signal1.type == "test-type-1"
      assert received_signal1.data == %{test: "data1"}

      # Verify first signal is in-flight
      state_after_first = :sys.get_state(pid)
      assert total_in_flight(state_after_first) == 1
      assert signal_log_id1 in in_flight_signal_ids(state_after_first)
      assert map_size(state_after_first.pending_signals) == 0

      # Send second signal
      send(pid, {:signal, {signal_log_id2, signal2}})

      # We should NOT receive the second signal yet (max_in_flight=1)
      refute_receive {:signal, _}, 100

      # Verify second signal is pending, not in-flight
      state_after_second = :sys.get_state(pid)
      assert total_in_flight(state_after_second) == 1
      assert map_size(state_after_second.pending_signals) == 1
      assert Map.has_key?(state_after_second.pending_signals, signal_log_id2)

      # Acknowledge first signal
      :ok = GenServer.call(pid, {:ack, signal_log_id1})

      # With UUID7, the checkpoint will be the timestamp from the UUID
      checkpoint_timestamp = ID.extract_timestamp(signal_log_id1)

      wait_until(fn ->
        state_after_ack = :sys.get_state(pid)

        state_after_ack.checkpoint == checkpoint_timestamp and
          total_in_flight(state_after_ack) == 1 and
          signal_log_id1 not in in_flight_signal_ids(state_after_ack) and
          signal_log_id2 in in_flight_signal_ids(state_after_ack) and
          map_size(state_after_ack.pending_signals) == 0
      end)

      # We should now receive the second signal
      assert_receive {:signal, received_signal2}, 500
      assert received_signal2.type == "test-type-2"
      assert received_signal2.data == %{test: "data2"}
    end

    test "handles batch acknowledgment", %{bus_pid: bus_pid, test_pid: test_pid} do
      # Set up the persistent subscription
      dispatch_config = [{:pid, [target: test_pid]}]

      opts = [
        bus_pid: bus_pid,
        path: "test/path",
        client_pid: test_pid,
        # Allow multiple in-flight signals
        max_in_flight: 10,
        bus_subscription: %Subscriber{
          id: ID.generate!(),
          path: "test/path",
          dispatch: dispatch_config
        }
      ]

      {:ok, pid} = PersistentSubscription.start_link(opts)

      # Create and send multiple signals with UUID7 IDs
      # Generate 5 signals with UUID7 IDs
      signals_with_ids =
        for i <- 1..5 do
          signal =
            Signal.new!(%{
              type: "test-type-#{i}",
              source: "/test",
              data: %{test: "data#{i}"}
            })

          # Generate a UUID7 for the signal log ID
          signal_log_id = ID.generate!()

          # Send signal with UUID7 ID
          send(pid, {:signal, {signal_log_id, signal}})

          {signal_log_id, signal}
        end

      # Extract just the signal_log_ids for later use
      signal_log_ids = Enum.map(signals_with_ids, fn {id, _} -> id end)

      # We should receive all signals
      received_types =
        Enum.map(1..5, fn _ ->
          assert_receive {:signal, received_signal}, 500
          received_signal.type
        end)

      assert Enum.sort(received_types) ==
               Enum.sort(Enum.map(1..5, fn i -> "test-type-#{i}" end))

      # Verify all signals are in-flight
      state_before_ack = :sys.get_state(pid)
      assert total_in_flight(state_before_ack) == 5

      # Select 3 signal IDs to acknowledge (first, third, and fifth)
      ids_to_ack = [
        Enum.at(signal_log_ids, 0),
        Enum.at(signal_log_ids, 2),
        Enum.at(signal_log_ids, 4)
      ]

      # Acknowledge signals in a batch
      :ok = GenServer.call(pid, {:ack, ids_to_ack})

      # Find the highest timestamp from the acknowledged IDs
      highest_timestamp =
        ids_to_ack
        |> Enum.map(&ID.extract_timestamp/1)
        |> Enum.max()

      wait_until(fn ->
        state_after_ack = :sys.get_state(pid)
        in_flight_ids = in_flight_signal_ids(state_after_ack)

        state_after_ack.checkpoint == highest_timestamp and
          total_in_flight(state_after_ack) == 2 and
          Enum.at(signal_log_ids, 0) not in in_flight_ids and
          Enum.at(signal_log_ids, 1) in in_flight_ids and
          Enum.at(signal_log_ids, 2) not in in_flight_ids and
          Enum.at(signal_log_ids, 3) in in_flight_ids and
          Enum.at(signal_log_ids, 4) not in in_flight_ids
      end)
    end

    test "returns {:error, :queue_full} when both in_flight and pending are full via handle_call",
         %{bus_pid: bus_pid, test_pid: test_pid} do
      dispatch_config = [{:pid, [target: test_pid]}]

      opts = [
        bus_pid: bus_pid,
        path: "test/path",
        client_pid: test_pid,
        max_in_flight: 2,
        max_pending: 2,
        bus_subscription: %Subscriber{
          id: ID.generate!(),
          path: "test/path",
          dispatch: dispatch_config
        }
      ]

      {:ok, pid} = PersistentSubscription.start_link(opts)

      # Send 4 signals (2 in-flight + 2 pending = at capacity)
      for i <- 1..4 do
        signal = Signal.new!(%{type: "test-#{i}", source: "/test", data: %{i: i}})
        signal_log_id = ID.generate!()
        result = GenServer.call(pid, {:signal, {signal_log_id, signal}})
        assert result == :ok
      end

      # Verify state
      state = :sys.get_state(pid)
      assert total_in_flight(state) == 2
      assert map_size(state.pending_signals) == 2

      # Fifth signal should be rejected
      signal5 = Signal.new!(%{type: "test-5", source: "/test", data: %{i: 5}})
      signal_log_id5 = ID.generate!()
      result = GenServer.call(pid, {:signal, {signal_log_id5, signal5}})
      assert result == {:error, :queue_full}

      # State should not have changed
      state_after = :sys.get_state(pid)
      assert total_in_flight(state_after) == 2
      assert map_size(state_after.pending_signals) == 2
    end

    test "supports cast-based signal batch enqueue with queue_full feedback", %{
      bus_pid: bus_pid,
      test_pid: test_pid
    } do
      dispatch_config = [{:pid, [target: test_pid]}]

      opts = [
        bus_pid: bus_pid,
        path: "test.path",
        client_pid: test_pid,
        max_in_flight: 1,
        max_pending: 1,
        bus_subscription: %Subscriber{
          id: ID.generate!(),
          path: "test.path",
          dispatch: dispatch_config
        }
      ]

      {:ok, pid} = PersistentSubscription.start_link(opts)

      signal1 = Signal.new!(%{type: "test.batch.1", source: "/test", data: %{i: 1}})
      signal2 = Signal.new!(%{type: "test.batch.2", source: "/test", data: %{i: 2}})
      signal3 = Signal.new!(%{type: "test.batch.3", source: "/test", data: %{i: 3}})

      log_id1 = ID.generate!()
      log_id2 = ID.generate!()
      log_id3 = ID.generate!()

      publish_ref = make_ref()

      GenServer.cast(
        pid,
        {:signal_batch, [{log_id1, signal1}, {log_id2, signal2}, {log_id3, signal3}], self(),
         publish_ref}
      )

      assert_receive {:persistent_enqueue_result, ^publish_ref, {:error, :queue_full}}, 500

      wait_until(fn ->
        state = :sys.get_state(pid)
        total_in_flight(state) == 1 and map_size(state.pending_signals) == 1
      end)
    end

    test "reconnect replay does not block callback responsiveness", %{
      bus_pid: bus_pid,
      test_pid: test_pid
    } do
      replay_signals =
        for index <- 1..50_000 do
          signal =
            Signal.new!(%{
              type: "test.replay.block",
              source: "/test",
              data: %{value: index}
            })

          {ID.generate!(), signal}
        end

      opts = [
        id: ID.generate!(),
        bus_pid: bus_pid,
        path: "test.replay.block",
        client_pid: test_pid,
        bus_subscription: %Subscriber{
          id: ID.generate!(),
          path: "test.replay.block",
          dispatch: {:pid, [target: test_pid]}
        }
      ]

      {:ok, pid} = PersistentSubscription.start_link(opts)
      sink_pid = spawn(fn -> Process.sleep(:infinity) end)
      GenServer.cast(pid, {:reconnect, sink_pid, replay_signals})
      parent = self()

      spawn(fn ->
        result =
          try do
            {:ok, GenServer.call(pid, :checkpoint, 200)}
          catch
            :exit, reason -> {:error, reason}
          end

        send(parent, {:checkpoint_result, result})
      end)

      try do
        assert_receive {:checkpoint_result, {:ok, 0}}, 300
      after
        Process.exit(sink_pid, :kill)
      end
    end

    test "drops signal when queue full via handle_info", %{bus_pid: bus_pid, test_pid: test_pid} do
      dispatch_config = [{:pid, [target: test_pid]}]

      opts = [
        bus_pid: bus_pid,
        path: "test/path",
        client_pid: test_pid,
        max_in_flight: 1,
        max_pending: 1,
        bus_subscription: %Subscriber{
          id: ID.generate!(),
          path: "test/path",
          dispatch: dispatch_config
        }
      ]

      {:ok, pid} = PersistentSubscription.start_link(opts)

      # Send 2 signals via handle_info (1 in-flight + 1 pending)
      for i <- 1..2 do
        signal = Signal.new!(%{type: "test-#{i}", source: "/test", data: %{i: i}})
        signal_log_id = ID.generate!()
        send(pid, {:signal, {signal_log_id, signal}})
      end

      wait_until(fn ->
        state = :sys.get_state(pid)
        total_in_flight(state) == 1 and map_size(state.pending_signals) == 1
      end)

      state = :sys.get_state(pid)
      assert total_in_flight(state) == 1
      assert map_size(state.pending_signals) == 1

      # Third signal should be dropped (handle_info can't return error)
      signal3 = Signal.new!(%{type: "test-3", source: "/test", data: %{i: 3}})
      signal_log_id3 = ID.generate!()
      send(pid, {:signal, {signal_log_id3, signal3}})

      wait_until(fn ->
        state = :sys.get_state(pid)
        total_in_flight(state) == 1 and map_size(state.pending_signals) == 1
      end)

      # State should not have changed
      state_after = :sys.get_state(pid)
      assert total_in_flight(state_after) == 1
      assert map_size(state_after.pending_signals) == 1
    end

    @tag :capture_log
    test "emits telemetry event on backpressure", %{bus_pid: bus_pid, test_pid: test_pid} do
      dispatch_config = [{:pid, [target: test_pid]}]

      opts = [
        bus_pid: bus_pid,
        path: "test/path",
        client_pid: test_pid,
        max_in_flight: 1,
        max_pending: 1,
        bus_subscription: %Subscriber{
          id: ID.generate!(),
          path: "test/path",
          dispatch: dispatch_config
        }
      ]

      {:ok, pid} = PersistentSubscription.start_link(opts)

      # Attach telemetry handler
      test_pid = self()
      handler_id = "test-backpressure-handler-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:jido, :signal, :subscription, :backpressure],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      # Fill up in-flight and pending
      for i <- 1..2 do
        signal = Signal.new!(%{type: "test-#{i}", source: "/test", data: %{i: i}})
        signal_log_id = ID.generate!()
        GenServer.call(pid, {:signal, {signal_log_id, signal}})
      end

      # Trigger backpressure
      signal3 = Signal.new!(%{type: "test-3", source: "/test", data: %{i: 3}})
      signal_log_id3 = ID.generate!()
      {:error, :queue_full} = GenServer.call(pid, {:signal, {signal_log_id3, signal3}})

      # Verify telemetry was emitted
      assert_receive {:telemetry_event, [:jido, :signal, :subscription, :backpressure], %{},
                      metadata},
                     500

      assert metadata.in_flight == 1
      assert metadata.pending == 1
      assert is_binary(metadata.subscription_id)

      :telemetry.detach(handler_id)
    end

    test "accepts more signals after ack drains queue", %{bus_pid: bus_pid, test_pid: test_pid} do
      dispatch_config = [{:pid, [target: test_pid]}]

      opts = [
        bus_pid: bus_pid,
        path: "test/path",
        client_pid: test_pid,
        max_in_flight: 1,
        max_pending: 1,
        bus_subscription: %Subscriber{
          id: ID.generate!(),
          path: "test/path",
          dispatch: dispatch_config
        }
      ]

      {:ok, pid} = PersistentSubscription.start_link(opts)

      # Fill up the queue
      signal1 = Signal.new!(%{type: "test-1", source: "/test", data: %{i: 1}})
      signal_log_id1 = ID.generate!()
      :ok = GenServer.call(pid, {:signal, {signal_log_id1, signal1}})

      signal2 = Signal.new!(%{type: "test-2", source: "/test", data: %{i: 2}})
      signal_log_id2 = ID.generate!()
      :ok = GenServer.call(pid, {:signal, {signal_log_id2, signal2}})

      # Queue is full now
      signal3 = Signal.new!(%{type: "test-3", source: "/test", data: %{i: 3}})
      signal_log_id3 = ID.generate!()
      assert {:error, :queue_full} = GenServer.call(pid, {:signal, {signal_log_id3, signal3}})

      # Acknowledge first signal
      :ok = GenServer.call(pid, {:ack, signal_log_id1})

      # Pending eventually moves to in-flight once dispatch/ack transitions settle
      wait_until(fn ->
        state = :sys.get_state(pid)
        total_in_flight(state) == 1 and map_size(state.pending_signals) == 0
      end)

      # Should be able to add more signals now
      signal4 = Signal.new!(%{type: "test-4", source: "/test", data: %{i: 4}})
      signal_log_id4 = ID.generate!()
      assert :ok = GenServer.call(pid, {:signal, {signal_log_id4, signal4}})
    end

    test "signals within limits are accepted", %{bus_pid: bus_pid, test_pid: test_pid} do
      dispatch_config = [{:pid, [target: test_pid]}]

      opts = [
        bus_pid: bus_pid,
        path: "test/path",
        client_pid: test_pid,
        max_in_flight: 5,
        max_pending: 5,
        bus_subscription: %Subscriber{
          id: ID.generate!(),
          path: "test/path",
          dispatch: dispatch_config
        }
      ]

      {:ok, pid} = PersistentSubscription.start_link(opts)

      # Send 10 signals (5 in-flight + 5 pending = exactly at capacity)
      for i <- 1..10 do
        signal = Signal.new!(%{type: "test-#{i}", source: "/test", data: %{i: i}})
        signal_log_id = ID.generate!()
        result = GenServer.call(pid, {:signal, {signal_log_id, signal}})
        assert result == :ok, "Signal #{i} should be accepted"
      end

      state = :sys.get_state(pid)
      assert total_in_flight(state) == 5
      assert map_size(state.pending_signals) == 5

      # 11th signal should fail
      signal11 = Signal.new!(%{type: "test-11", source: "/test", data: %{i: 11}})
      signal_log_id11 = ID.generate!()
      assert {:error, :queue_full} = GenServer.call(pid, {:signal, {signal_log_id11, signal11}})
    end
  end

  defp total_in_flight(state) do
    map_size(state.in_flight_signals) + map_size(state.dispatch_tasks)
  end

  defp in_flight_signal_ids(state) do
    task_signal_ids =
      Enum.map(state.dispatch_tasks, fn {_task_ref, {_task, signal_log_id, _signal}} ->
        signal_log_id
      end)

    Map.keys(state.in_flight_signals) ++ task_signal_ids
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: flunk("condition not met in wait_until/2")

  defp wait_until(fun, attempts) when is_function(fun, 0) do
    if fun.() do
      :ok
    else
      receive do
      after
        10 -> wait_until(fun, attempts - 1)
      end
    end
  end
end
