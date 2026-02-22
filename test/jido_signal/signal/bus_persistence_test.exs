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

    test "signals_since query remains responsive under concurrent publish", %{bus_pid: bus_pid} do
      signals =
        for i <- 1..25 do
          Signal.new!(%{
            type: "test.concurrent.#{i}",
            source: "/test",
            data: %{value: i}
          })
        end

      publish_task = Task.async(fn -> Bus.publish(bus_pid, signals) end)
      query_task = Task.async(fn -> GenServer.call(bus_pid, {:signals_since, 0}) end)

      assert {:ok, _recorded_signals} = Task.await(publish_task, 1_000)
      assert {:ok, entries} = Task.await(query_task, 1_000)
      assert is_list(entries)
    end

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
      assert map_size(state_after_first.in_flight_signals) == 1
      assert Map.has_key?(state_after_first.in_flight_signals, signal_log_id1)
      assert map_size(state_after_first.pending_signals) == 0

      # Send second signal
      send(pid, {:signal, {signal_log_id2, signal2}})

      # We should NOT receive the second signal yet (max_in_flight=1)
      refute_receive {:signal, _}, 100

      # Verify second signal is pending, not in-flight
      state_after_second = :sys.get_state(pid)
      assert map_size(state_after_second.in_flight_signals) == 1
      assert map_size(state_after_second.pending_signals) == 1
      assert Map.has_key?(state_after_second.pending_signals, signal_log_id2)

      # Acknowledge first signal
      :ok = GenServer.call(pid, {:ack, signal_log_id1})

      # Verify checkpoint was updated
      state_after_ack = :sys.get_state(pid)

      # With UUID7, the checkpoint will be the timestamp from the UUID
      checkpoint_timestamp = ID.extract_timestamp(signal_log_id1)
      assert state_after_ack.checkpoint == checkpoint_timestamp

      # First signal should be removed from in-flight
      assert map_size(state_after_ack.in_flight_signals) == 1
      refute Map.has_key?(state_after_ack.in_flight_signals, signal_log_id1)

      # Second signal should now be in-flight
      assert Map.has_key?(state_after_ack.in_flight_signals, signal_log_id2)

      # Pending signals should be empty
      assert map_size(state_after_ack.pending_signals) == 0

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
      for i <- 1..5 do
        assert_receive {:signal, received_signal}, 500
        assert received_signal.type == "test-type-#{i}"
        assert received_signal.data == %{test: "data#{i}"}
      end

      # Verify all signals are in-flight
      state_before_ack = :sys.get_state(pid)
      assert map_size(state_before_ack.in_flight_signals) == 5

      # Select 3 signal IDs to acknowledge (first, third, and fifth)
      ids_to_ack = [
        Enum.at(signal_log_ids, 0),
        Enum.at(signal_log_ids, 2),
        Enum.at(signal_log_ids, 4)
      ]

      # Acknowledge signals in a batch
      :ok = GenServer.call(pid, {:ack, ids_to_ack})

      # Verify checkpoint was updated to highest acknowledged ID timestamp
      state_after_ack = :sys.get_state(pid)

      # Find the highest timestamp from the acknowledged IDs
      highest_timestamp =
        ids_to_ack
        |> Enum.map(&ID.extract_timestamp/1)
        |> Enum.max()

      assert state_after_ack.checkpoint == highest_timestamp

      # The acknowledged signals should be removed from in-flight
      assert map_size(state_after_ack.in_flight_signals) == 2

      # First, third, and fifth signals should be removed
      refute Map.has_key?(state_after_ack.in_flight_signals, Enum.at(signal_log_ids, 0))
      assert Map.has_key?(state_after_ack.in_flight_signals, Enum.at(signal_log_ids, 1))
      refute Map.has_key?(state_after_ack.in_flight_signals, Enum.at(signal_log_ids, 2))
      assert Map.has_key?(state_after_ack.in_flight_signals, Enum.at(signal_log_ids, 3))
      refute Map.has_key?(state_after_ack.in_flight_signals, Enum.at(signal_log_ids, 4))
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
      assert map_size(state.in_flight_signals) == 2
      assert map_size(state.pending_signals) == 2

      # Fifth signal should be rejected
      signal5 = Signal.new!(%{type: "test-5", source: "/test", data: %{i: 5}})
      signal_log_id5 = ID.generate!()
      result = GenServer.call(pid, {:signal, {signal_log_id5, signal5}})
      assert result == {:error, :queue_full}

      # State should not have changed
      state_after = :sys.get_state(pid)
      assert map_size(state_after.in_flight_signals) == 2
      assert map_size(state_after.pending_signals) == 2
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

      # Allow messages to be processed
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert map_size(state.in_flight_signals) == 1
      assert map_size(state.pending_signals) == 1

      # Third signal should be dropped (handle_info can't return error)
      signal3 = Signal.new!(%{type: "test-3", source: "/test", data: %{i: 3}})
      signal_log_id3 = ID.generate!()
      send(pid, {:signal, {signal_log_id3, signal3}})

      Process.sleep(50)

      # State should not have changed
      state_after = :sys.get_state(pid)
      assert map_size(state_after.in_flight_signals) == 1
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

      # Now pending should move to in-flight, leaving room in pending
      state = :sys.get_state(pid)
      assert map_size(state.in_flight_signals) == 1
      assert map_size(state.pending_signals) == 0

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
      assert map_size(state.in_flight_signals) == 5
      assert map_size(state.pending_signals) == 5

      # 11th signal should fail
      signal11 = Signal.new!(%{type: "test-11", source: "/test", data: %{i: 11}})
      signal_log_id11 = ID.generate!()
      assert {:error, :queue_full} = GenServer.call(pid, {:signal, {signal_log_id11, signal11}})
    end
  end
end
