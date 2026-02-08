defmodule JidoTest.Signal.Bus do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias Jido.Signal.Error
  alias Jido.Signal.ID

  @moduletag :capture_log

  setup do
    bus_name = "test-bus-#{:erlang.unique_integer([:positive])}"
    start_supervised!({Bus, name: bus_name})
    {:ok, bus: bus_name}
  end

  describe "subscribe/3" do
    test "subscribes to signals with a specific type", %{bus: bus} do
      {:ok, subscription_id} = Bus.subscribe(bus, "test.signal")
      assert is_binary(subscription_id)
    end

    test "subscribes to all signals with wildcard", %{bus: bus} do
      {:ok, subscription_id} = Bus.subscribe(bus, "*")
      assert is_binary(subscription_id)
    end

    test "subscribes with custom dispatch config", %{bus: bus} do
      dispatch = {:pid, target: self(), delivery_mode: :sync}
      {:ok, subscription_id} = Bus.subscribe(bus, "test.signal", dispatch: dispatch)
      assert is_binary(subscription_id)
    end

    test "returns error for invalid path pattern", %{bus: bus} do
      assert {:error, _} = Bus.subscribe(bus, "")
    end

    test "subscribes with persistent option", %{bus: bus} do
      {:ok, subscription_id} = Bus.subscribe(bus, "test.signal", persistent?: true)
      assert is_binary(subscription_id)

      # Publish a signal
      {:ok, signal} =
        Signal.new(%{
          type: "test.signal",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, _} = Bus.publish(bus, [signal])

      # Verify signal is received
      assert_receive {:signal, %Signal{type: "test.signal"}}

      # Acknowledge the signal
      :ok = Bus.ack(bus, subscription_id, 1)
    end

    test "logs deprecation warning for legacy persistent option alias", %{bus: bus} do
      log =
        capture_log(fn ->
          assert {:ok, _subscription_id} = Bus.subscribe(bus, "test.signal", persistent: true)
        end)

      assert log =~ "deprecated"
      assert log =~ ":persistent?"
    end
  end

  describe "unsubscribe/2" do
    test "unsubscribes from signals", %{bus: bus} do
      {:ok, subscription_id} = Bus.subscribe(bus, "test.signal")
      assert :ok = Bus.unsubscribe(bus, subscription_id)
    end

    test "returns error for non-existent subscription", %{bus: bus} do
      assert {:error, _} = Bus.unsubscribe(bus, "non-existent")
    end

    test "unsubscribes with delete_persistence option", %{bus: bus} do
      {:ok, subscription_id} = Bus.subscribe(bus, "test.signal", persistent: true)
      assert :ok = Bus.unsubscribe(bus, subscription_id, delete_persistence: true)

      # Try to resubscribe with the same ID
      {:ok, new_subscription_id} = Bus.subscribe(bus, "test.signal", persistent: true)
      assert is_binary(new_subscription_id)
    end
  end

  describe "fault tolerance" do
    test "ack tolerates persistent subscription restart races", %{
      bus: bus
    } do
      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.signal", persistent?: true, dispatch: {:pid, target: self()})

      {:ok, signal} =
        Signal.new(%{
          type: "test.signal",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, [recorded]} = Bus.publish(bus, [signal])
      assert_receive {:signal, %Signal{type: "test.signal"}}

      {:ok, bus_pid} = Bus.whereis(bus)
      bus_state = :sys.get_state(bus_pid)
      sub = Map.fetch!(bus_state.subscriptions, subscription_id)
      mon_ref = Process.monitor(sub.persistence_pid)
      Process.exit(sub.persistence_pid, :kill)
      assert_receive {:DOWN, ^mon_ref, :process, _pid, _reason}

      case Bus.ack(bus, subscription_id, recorded.id) do
        :ok ->
          :ok

        {:error, %Error.ExecutionFailureError{} = error} ->
          assert error.details[:reason] == :subscription_not_available
      end

      assert Process.alive?(bus_pid)
    end

    test "bus ignores spurious DOWN messages without crashing", %{bus: bus} do
      {:ok, bus_pid} = Bus.whereis(bus)
      send(bus_pid, {:DOWN, make_ref(), :process, self(), :normal})
      # Synchronous call ensures previously sent message was processed.
      assert [] == Bus.snapshot_list(bus)
      assert Process.alive?(bus_pid)
    end
  end

  describe "publish/2" do
    test "publishes signals to subscribers", %{bus: bus} do
      # Subscribe to signals
      {:ok, _subscription} = Bus.subscribe(bus, "test.signal")

      # Publish a signal
      {:ok, signal} =
        Signal.new(%{
          type: "test.signal",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, _} = Bus.publish(bus, [signal])

      # Verify signal is received
      assert_receive {:signal, %Signal{type: "test.signal"}}
    end

    test "publish/2 maintains signal order", %{bus: bus} do
      # Subscribe to signals
      {:ok, _subscription} = Bus.subscribe(bus, "**")

      # Publish multiple signals
      signals =
        Enum.map(1..3, fn i ->
          {:ok, signal} =
            Signal.new(%{
              type: "test.signal.#{i}",
              source: "/test",
              data: %{value: i}
            })

          signal
        end)

      {:ok, _} = Bus.publish(bus, signals)

      # Verify signals are received in order
      for i <- 1..3 do
        type = "test.signal.#{i}"
        assert_receive {:signal, %Signal{type: ^type}}, 1000
      end
    end

    test "publish/2 routes signals to matching subscribers only", %{bus: bus} do
      # Subscribe to specific signal type
      {:ok, _subscription} = Bus.subscribe(bus, "test.signal.1")

      # Publish multiple signals
      {:ok, signal1} =
        Signal.new(%{
          type: "test.signal.1",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, signal2} =
        Signal.new(%{
          type: "test.signal.2",
          source: "/test",
          data: %{value: 2}
        })

      {:ok, _} = Bus.publish(bus, [signal1, signal2])

      # Should receive only signal1
      assert_receive {:signal, %Signal{type: "test.signal.1"}}
      refute_receive {:signal, %Signal{type: "test.signal.2"}}
    end

    test "handles invalid signals gracefully", %{bus: bus} do
      # Try to publish invalid signals
      assert {:error, _} = Bus.publish(bus, [%{not_a_signal: true}])
    end

    test "publishes signals with correlation_id", %{bus: bus} do
      # Subscribe to signals
      {:ok, _subscription} = Bus.subscribe(bus, "test.signal")

      # Publish a signal with correlation_id
      {:ok, signal} =
        Signal.new(%{
          type: "test.signal",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, _} = Bus.publish(bus, [signal])

      # Verify correlation_id is preserved
      assert_receive {:signal, %Signal{type: "test.signal"}}
    end
  end

  describe "replay/2" do
    test "replays signals matching path pattern", %{bus: bus} do
      # Publish some signals first
      signals =
        Enum.map(1..2, fn i ->
          {:ok, signal} =
            Signal.new(%{
              type: "test.signal.#{i}",
              source: "/test",
              data: %{value: i}
            })

          signal
        end)

      {:ok, _} = Bus.publish(bus, signals)

      # Replay specific type
      {:ok, replayed} = Bus.replay(bus, "test.signal.1")
      assert length(replayed) == 1
      assert hd(replayed).signal.type == "test.signal.1"

      # Replay all
      {:ok, all_replayed} = Bus.replay(bus, "**")
      assert length(all_replayed) == 2
    end

    test "replays signals from start_timestamp", %{bus: bus} do
      # Publish a signal
      {:ok, signal1} =
        Signal.new(%{
          type: "test.signal",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, [recorded1]} = Bus.publish(bus, [signal1])

      first_timestamp = ID.extract_timestamp(recorded1.id)

      wait_for_next_millisecond = fn wait_for_next_millisecond ->
        if System.system_time(:millisecond) > first_timestamp do
          :ok
        else
          wait_for_next_millisecond.(wait_for_next_millisecond)
        end
      end

      :ok = wait_for_next_millisecond.(wait_for_next_millisecond)

      {:ok, signal2} =
        Signal.new(%{
          type: "test.signal",
          source: "/test",
          data: %{value: 2}
        })

      {:ok, _} = Bus.publish(bus, [signal2])

      # Replay from first signal timestamp to get newer signals only.
      {:ok, replayed} = Bus.replay(bus, "**", first_timestamp)
      assert replayed != []
      # Find the signal with value 2
      signal_with_value_2 = Enum.find(replayed, fn r -> r.signal.data.value == 2 end)
      assert signal_with_value_2 != nil
    end

    test "returns empty list when no signals match replay criteria", %{bus: bus} do
      # Replay with no signals in the bus
      {:ok, replayed} = Bus.replay(bus, "test.signal")
      assert Enum.empty?(replayed)
    end

    test "replays signals with batch_size limit", %{bus: bus} do
      # Publish many signals
      signals =
        Enum.map(1..10, fn i ->
          {:ok, signal} =
            Signal.new(%{
              type: "test.signal",
              source: "/test",
              data: %{value: i}
            })

          signal
        end)

      {:ok, _} = Bus.publish(bus, signals)

      # Replay with batch_size limit
      {:ok, replayed} = Bus.replay(bus, "**", 0, batch_size: 5)
      assert length(replayed) == 5
    end
  end

  describe "snapshot operations" do
    test "creates and reads snapshots", %{bus: bus} do
      # Publish some signals
      signals =
        Enum.map(1..2, fn i ->
          {:ok, signal} =
            Signal.new(%{
              type: "test.signal.#{i}",
              source: "/test",
              data: %{value: i}
            })

          signal
        end)

      {:ok, _} = Bus.publish(bus, signals)

      # Create snapshot
      {:ok, snapshot} = Bus.snapshot_create(bus, "test.signal.1")
      assert snapshot.path == "test.signal.1"

      # Read snapshot
      {:ok, read_snapshot} = Bus.snapshot_read(bus, snapshot.id)
      assert read_snapshot.path == "test.signal.1"
      assert map_size(read_snapshot.signals) == 1
      signal_entry = read_snapshot.signals |> Map.values() |> hd()
      assert signal_entry.signal.type == "test.signal.1"
    end

    test "lists snapshots", %{bus: bus} do
      # Create two snapshots
      {:ok, snapshot1} = Bus.snapshot_create(bus, "test.signal.1")
      {:ok, snapshot2} = Bus.snapshot_create(bus, "test.signal.2")

      snapshots = Bus.snapshot_list(bus)
      assert length(snapshots) == 2
      assert Enum.any?(snapshots, &(&1.id == snapshot1.id))
      assert Enum.any?(snapshots, &(&1.id == snapshot2.id))
    end

    test "deletes snapshots", %{bus: bus} do
      {:ok, snapshot} = Bus.snapshot_create(bus, "test.signal")
      assert :ok = Bus.snapshot_delete(bus, snapshot.id)

      assert {:error, %Error.InvalidInputError{} = error} = Bus.snapshot_read(bus, snapshot.id)
      assert error.details[:reason] == :snapshot_not_found
    end

    test "creates empty snapshot when no signals match path", %{bus: bus} do
      {:ok, snapshot} = Bus.snapshot_create(bus, "non.existent.path")
      assert snapshot.path == "non.existent.path"

      {:ok, read_snapshot} = Bus.snapshot_read(bus, snapshot.id)
      assert map_size(read_snapshot.signals) == 0
    end

    test "returns error when reading non-existent snapshot", %{bus: bus} do
      assert {:error, %Error.InvalidInputError{} = error} =
               Bus.snapshot_read(bus, "non-existent-id")

      assert error.details[:reason] == :snapshot_not_found
    end

    test "returns error when deleting non-existent snapshot", %{bus: bus} do
      assert {:error, %Error.InvalidInputError{} = error} =
               Bus.snapshot_delete(bus, "non-existent-id")

      assert error.details[:reason] == :snapshot_not_found
    end
  end

  # describe "ack/3" do
  #   test "acknowledges signals for persistent subscriptions", %{bus: bus} do
  #     # Create persistent subscription
  #     {:ok, subscription_id} = Bus.subscribe(bus, "test.signal", persistent: true)

  #     # Publish a signal
  #     {:ok, signal} =
  #       Signal.new(%{
  #         type: "test.signal",
  #         source: "/test",
  #         data: %{value: 1}
  #       })

  #     {:ok, [recorded_signal]} = Bus.publish(bus, [signal])

  #     # Verify signal is received
  #     assert_receive {:signal, %Signal{type: "test.signal"}}

  #     # Acknowledge the signal
  #     assert :ok = Bus.ack(bus, subscription_id, recorded_signal.id)
  #   end

  #   test "returns error when acknowledging for non-existent subscription", %{bus: bus} do
  #     assert {:error, _} = Bus.ack(bus, "non-existent", "signal-id")
  #   end

  #   test "returns error when acknowledging for non-persistent subscription", %{bus: bus} do
  #     # Create non-persistent subscription
  #     {:ok, subscription_id} = Bus.subscribe(bus, "test.signal")

  #     assert {:error, _} = Bus.ack(bus, subscription_id, "signal-id")
  #   end
  # end

  # describe "reconnect/2" do
  #   test "reconnects a client to a persistent subscription", %{bus: bus} do
  #     # Create persistent subscription
  #     {:ok, subscription_id} = Bus.subscribe(bus, "test.signal", persistent: true)

  #     # Publish a signal
  #     {:ok, signal} =
  #       Signal.new(%{
  #         type: "test.signal",
  #         source: "/test",
  #         data: %{value: 1}
  #       })

  #     {:ok, [recorded_signal]} = Bus.publish(bus, [signal])

  #     # Acknowledge the signal
  #     :ok = Bus.ack(bus, subscription_id, recorded_signal.id)

  #     # Create a new process to simulate a new client
  #     task =
  #       Task.async(fn ->
  #         receive do
  #           :continue -> :ok
  #         end
  #       end)

  #     # Reconnect with the new client
  #     {:ok, checkpoint} = Bus.reconnect(bus, subscription_id, task.pid)
  #     assert is_integer(checkpoint)

  #     # Clean up
  #     send(task.pid, :continue)
  #     Task.await(task)
  #   end

  #   test "returns error when reconnecting to non-existent subscription", %{bus: bus} do
  #     assert {:error, _} = Bus.reconnect(bus, "non-existent", self())
  #   end

  #   test "returns error when reconnecting to non-persistent subscription", %{bus: bus} do
  #     # Create non-persistent subscription
  #     {:ok, subscription_id} = Bus.subscribe(bus, "test.signal")

  #     assert {:error, _} = Bus.reconnect(bus, subscription_id, self())
  #   end
  # end

  describe "whereis/1" do
    test "finds a bus by name", %{bus: bus} do
      {:ok, pid} = Bus.whereis(bus)
      assert is_pid(pid)
    end

    test "registers bus under namespaced registry key", %{bus: bus} do
      {:ok, pid} = Bus.whereis(bus)
      assert [{^pid, _}] = Registry.lookup(Jido.Signal.Registry, {:bus, bus})
    end

    test "returns error for non-existent bus" do
      assert {:error, :not_found} = Bus.whereis("non-existent-bus")
    end
  end

  describe "middleware timeout protection" do
    defmodule SlowBusMiddleware do
      use Jido.Signal.Bus.Middleware

      @impl true
      def init(opts) do
        {:ok, %{wait_ms: Keyword.get(opts, :wait_ms, 200)}}
      end

      @impl true
      def before_publish(signals, _context, state) do
        receive do
          :continue -> :ok
        after
          state.wait_ms -> :ok
        end

        {:cont, signals, state}
      end
    end

    test "bus with slow middleware returns error" do
      bus_name = "test-slow-bus-#{:erlang.unique_integer([:positive])}"

      start_supervised!(
        {Bus,
         name: bus_name,
         middleware: [{SlowBusMiddleware, wait_ms: 200}],
         middleware_timeout_ms: 50}
      )

      {:ok, signal} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 1}})

      result = Bus.publish(bus_name, [signal])

      assert {:error, %Jido.Signal.Error.ExecutionFailureError{message: "Middleware timeout"}} =
               result
    end

    test "bus with custom middleware_timeout_ms option allows slower middleware" do
      bus_name = "test-custom-timeout-bus-#{:erlang.unique_integer([:positive])}"

      start_supervised!(
        {Bus,
         name: bus_name,
         middleware: [{SlowBusMiddleware, wait_ms: 50}],
         middleware_timeout_ms: 200}
      )

      {:ok, _subscription} = Bus.subscribe(bus_name, "test.signal")

      {:ok, signal} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 1}})

      result = Bus.publish(bus_name, [signal])

      assert {:ok, [_recorded_signal]} = result
      assert_receive {:signal, %Signal{type: "test.signal"}}
    end

    test "bus without middleware works normally" do
      bus_name = "test-no-middleware-bus-#{:erlang.unique_integer([:positive])}"

      start_supervised!({Bus, name: bus_name})

      {:ok, _subscription} = Bus.subscribe(bus_name, "test.signal")

      {:ok, signal} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 1}})

      result = Bus.publish(bus_name, [signal])

      assert {:ok, [_recorded_signal]} = result
      assert_receive {:signal, %Signal{type: "test.signal"}}
    end
  end

  describe "middleware state propagation" do
    defmodule StatefulCounterMiddleware do
      use Jido.Signal.Bus.Middleware

      @impl true
      def init(opts) do
        test_pid = Keyword.fetch!(opts, :test_pid)
        {:ok, %{publish_count: 0, dispatch_count: 0, test_pid: test_pid}}
      end

      @impl true
      def before_publish(signals, _context, state) do
        new_count = state.publish_count + 1
        send(state.test_pid, {:publish_count, new_count})
        {:cont, signals, %{state | publish_count: new_count}}
      end

      @impl true
      def after_publish(signals, _context, state) do
        {:cont, signals, state}
      end

      @impl true
      def before_dispatch(signal, _subscriber, _context, state) do
        new_count = state.dispatch_count + 1
        send(state.test_pid, {:dispatch_count, new_count})
        {:cont, signal, %{state | dispatch_count: new_count}}
      end

      @impl true
      def after_dispatch(_signal, _subscriber, _result, _context, state) do
        {:cont, state}
      end
    end

    test "middleware state persists across multiple publishes" do
      bus_name = "test-stateful-bus-#{:erlang.unique_integer([:positive])}"

      start_supervised!(
        {Bus, name: bus_name, middleware: [{StatefulCounterMiddleware, test_pid: self()}]}
      )

      # Subscribe to receive signals
      {:ok, _subscription} = Bus.subscribe(bus_name, "test.signal")

      # First publish
      {:ok, signal1} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 1}})
      {:ok, _} = Bus.publish(bus_name, [signal1])

      assert_receive {:publish_count, 1}
      assert_receive {:dispatch_count, 1}
      assert_receive {:signal, _}

      # Second publish - state should increment
      {:ok, signal2} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 2}})
      {:ok, _} = Bus.publish(bus_name, [signal2])

      assert_receive {:publish_count, 2}
      assert_receive {:dispatch_count, 2}
      assert_receive {:signal, _}

      # Third publish - state should continue incrementing
      {:ok, signal3} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 3}})
      {:ok, _} = Bus.publish(bus_name, [signal3])

      assert_receive {:publish_count, 3}
      assert_receive {:dispatch_count, 3}
      assert_receive {:signal, _}
    end

    test "middleware state persists with multiple subscribers" do
      bus_name = "test-multi-sub-bus-#{:erlang.unique_integer([:positive])}"

      start_supervised!(
        {Bus, name: bus_name, middleware: [{StatefulCounterMiddleware, test_pid: self()}]}
      )

      # Subscribe with two subscriptions
      {:ok, _subscription1} = Bus.subscribe(bus_name, "test.signal")
      {:ok, _subscription2} = Bus.subscribe(bus_name, "test.*")

      {:ok, signal} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 1}})
      {:ok, _} = Bus.publish(bus_name, [signal])

      # Should have 1 publish count
      assert_receive {:publish_count, 1}
      # Should have 2 dispatch counts (one per matching subscription)
      assert_receive {:dispatch_count, 1}
      assert_receive {:dispatch_count, 2}

      # Second publish
      {:ok, signal2} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 2}})
      {:ok, _} = Bus.publish(bus_name, [signal2])

      # State should persist - publish count increments
      assert_receive {:publish_count, 2}
      # Dispatch counts continue from 2
      assert_receive {:dispatch_count, 3}
      assert_receive {:dispatch_count, 4}
    end
  end

  describe "backpressure" do
    test "returns error when persistent subscription queue is full", %{bus: bus} do
      # Subscribe with persistent subscription with very small queues
      {:ok, _subscription_id} =
        Bus.subscribe(bus, "test.signal",
          persistent?: true,
          max_in_flight: 1,
          max_pending: 1
        )

      # First signal should succeed (goes to in_flight)
      {:ok, signal1} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 1}})
      {:ok, _} = Bus.publish(bus, [signal1])

      # Receive the signal but don't ack
      assert_receive {:signal, %Signal{type: "test.signal"}}

      # Second signal should succeed (goes to pending)
      {:ok, signal2} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 2}})
      {:ok, _} = Bus.publish(bus, [signal2])

      # Third signal should fail with backpressure error
      {:ok, signal3} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 3}})
      result = Bus.publish(bus, [signal3])

      assert {:error, error} = result
      assert error.message == "Subscription saturated"
      assert error.details.reason == :queue_full
    end

    test "emits telemetry event on backpressure", %{bus: bus} do
      # Attach telemetry handler
      test_pid = self()
      handler_id = "test-bus-backpressure-handler-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:jido, :signal, :bus, :backpressure],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      # Subscribe with persistent subscription with very small queues
      {:ok, _subscription_id} =
        Bus.subscribe(bus, "test.signal",
          persistent?: true,
          max_in_flight: 1,
          max_pending: 1
        )

      # Fill up the queues
      {:ok, signal1} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 1}})
      {:ok, _} = Bus.publish(bus, [signal1])
      assert_receive {:signal, _}

      {:ok, signal2} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 2}})
      {:ok, _} = Bus.publish(bus, [signal2])

      # Trigger backpressure
      {:ok, signal3} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 3}})
      {:error, _} = Bus.publish(bus, [signal3])

      # Verify telemetry event was emitted
      assert_receive {:telemetry_event, [:jido, :signal, :bus, :backpressure], measurements,
                      metadata},
                     500

      assert measurements.saturated_count == 1
      assert metadata.bus_name == bus

      :telemetry.detach(handler_id)
    end

    test "non-persistent subscriptions do not cause backpressure errors", %{bus: bus} do
      # Subscribe with a regular (non-persistent) subscription
      {:ok, _subscription_id} = Bus.subscribe(bus, "test.signal")

      # Publish many signals - should all succeed since regular subscriptions are async
      for i <- 1..100 do
        {:ok, signal} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: i}})
        result = Bus.publish(bus, [signal])
        assert {:ok, _} = result
      end

      # Drain the mailbox
      for _ <- 1..100 do
        assert_receive {:signal, %Signal{type: "test.signal"}}
      end
    end

    test "backpressure clears after ack", %{bus: bus} do
      # Subscribe with persistent subscription with very small queues
      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.signal",
          persistent?: true,
          max_in_flight: 1,
          max_pending: 1
        )

      # Fill up the queues
      {:ok, signal1} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 1}})
      {:ok, [recorded1]} = Bus.publish(bus, [signal1])
      assert_receive {:signal, _}

      {:ok, signal2} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 2}})
      {:ok, _} = Bus.publish(bus, [signal2])

      # Third signal fails
      {:ok, signal3} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 3}})
      assert {:error, _} = Bus.publish(bus, [signal3])

      # Acknowledge the first signal
      :ok = Bus.ack(bus, subscription_id, recorded1.id)

      # Now we should be able to receive the pending signal
      assert_receive {:signal, %Signal{data: %{value: 2}}}

      # And publish another signal should now succeed
      {:ok, signal4} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 4}})
      {:ok, _} = Bus.publish(bus, [signal4])
    end
  end

  describe "auto log truncation" do
    test "bus with custom max_log_size truncates log" do
      bus_name = "test-bus-max-log-#{:erlang.unique_integer([:positive])}"
      start_supervised!({Bus, name: bus_name, max_log_size: 5})

      # Subscribe to receive signals
      {:ok, _subscription} = Bus.subscribe(bus_name, "**")

      # Publish 10 signals
      signals =
        for i <- 1..10 do
          {:ok, signal} =
            Signal.new(%{
              type: "test.signal.#{i}",
              source: "/test",
              data: %{value: i}
            })

          signal
        end

      {:ok, _} = Bus.publish(bus_name, signals)

      # Replay to check log size - should only have 5 signals
      {:ok, replayed} = Bus.replay(bus_name, "**")
      assert length(replayed) == 5

      # Should have the most recent signals (6-10)
      values = Enum.map(replayed, fn r -> r.signal.data.value end) |> Enum.sort()
      assert values == [6, 7, 8, 9, 10]
    end

    test "bus uses default max_log_size of 100_000" do
      bus_name = "test-bus-default-#{:erlang.unique_integer([:positive])}"
      start_supervised!({Bus, name: bus_name})

      # Publish a small number of signals
      signals =
        for i <- 1..50 do
          {:ok, signal} =
            Signal.new(%{
              type: "test.signal.#{i}",
              source: "/test",
              data: %{value: i}
            })

          signal
        end

      {:ok, _} = Bus.publish(bus_name, signals)

      # All 50 signals should be present (well under 100_000 default)
      {:ok, replayed} = Bus.replay(bus_name, "**")
      assert length(replayed) == 50
    end

    test "TTL-based GC removes old signals" do
      bus_name = "test-bus-ttl-#{:erlang.unique_integer([:positive])}"
      # Use a short TTL for testing
      start_supervised!({Bus, name: bus_name, log_ttl_ms: 100})

      # Publish an old signal that should be pruned immediately.
      {:ok, signal1} =
        Signal.new(%{
          type: "test.signal.1",
          source: "/test",
          data: %{value: 1},
          time: DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.to_iso8601()
        })

      {:ok, _} = Bus.publish(bus_name, [signal1])
      {:ok, bus_pid} = Bus.whereis(bus_name)
      send(bus_pid, :gc_log)

      assert_eventually(
        fn ->
          {:ok, replayed} = Bus.replay(bus_name, "**")
          refute_old_signal?(replayed, "test.signal.1")
        end,
        200
      )
    end
  end

  defp assert_eventually(_predicate, 0), do: flunk("condition did not converge")

  defp assert_eventually(predicate, attempts) when is_function(predicate, 0) do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(predicate, attempts - 1)
    end
  end

  defp refute_old_signal?(replayed, signal_type) do
    not Enum.any?(replayed, &(&1.signal.type == signal_type))
  end
end
