defmodule JidoTest.Signal.Bus.PersistentSubscriptionCheckpointTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias Jido.Signal.ID
  alias Jido.Signal.Journal.Adapters.ETS, as: ETSAdapter

  @moduletag :capture_log

  describe "checkpoint persistence with journal adapter" do
    setup do
      {:ok, journal_pid} = ETSAdapter.start_link("test_journal_")
      bus_name = :"test_bus_#{:erlang.unique_integer([:positive])}"

      start_supervised!(
        {Bus, name: bus_name, journal_adapter: ETSAdapter, journal_pid: journal_pid}
      )

      {:ok, bus: bus_name, journal_pid: journal_pid}
    end

    test "checkpoint is persisted when signal is acknowledged", %{
      bus: bus,
      journal_pid: journal_pid
    } do
      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.**", persistent?: true, dispatch: {:pid, target: self()})

      {:ok, signal} =
        Signal.new(%{
          type: "test.signal",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, [recorded_signal]} = Bus.publish(bus, [signal])

      assert_receive {:signal, %Signal{type: "test.signal"}}

      :ok = Bus.ack(bus, subscription_id, recorded_signal.id)

      Process.sleep(50)

      checkpoint_key = "#{bus}:#{subscription_id}"
      {:ok, checkpoint} = ETSAdapter.get_checkpoint(checkpoint_key, journal_pid)
      assert checkpoint > 0
    end

    test "checkpoint persists across PersistentSubscription restart", %{
      bus: bus,
      journal_pid: journal_pid
    } do
      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.**", persistent?: true, dispatch: {:pid, target: self()})

      {:ok, signal1} =
        Signal.new(%{
          type: "test.signal.one",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, signal2} =
        Signal.new(%{
          type: "test.signal.two",
          source: "/test",
          data: %{value: 2}
        })

      {:ok, [recorded1]} = Bus.publish(bus, [signal1])
      assert_receive {:signal, %Signal{type: "test.signal.one"}}
      :ok = Bus.ack(bus, subscription_id, recorded1.id)

      Process.sleep(50)

      {:ok, [recorded2]} = Bus.publish(bus, [signal2])
      assert_receive {:signal, %Signal{type: "test.signal.two"}}
      :ok = Bus.ack(bus, subscription_id, recorded2.id)

      Process.sleep(50)

      checkpoint_key = "#{bus}:#{subscription_id}"
      {:ok, checkpoint_before} = ETSAdapter.get_checkpoint(checkpoint_key, journal_pid)
      assert checkpoint_before > 0

      bus_state = Bus.whereis(bus) |> elem(1) |> :sys.get_state()
      subscription = Map.get(bus_state.subscriptions, subscription_id)
      assert subscription.persistence_pid != nil

      old_persistent_pid = subscription.persistence_pid
      GenServer.stop(old_persistent_pid, :normal)

      Process.sleep(100)

      {:ok, checkpoint_after} = ETSAdapter.get_checkpoint(checkpoint_key, journal_pid)
      assert checkpoint_after == checkpoint_before
    end

    test "batch ack persists checkpoint for highest timestamp", %{
      bus: bus,
      journal_pid: journal_pid
    } do
      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.**", persistent?: true, dispatch: {:pid, target: self()})

      signals =
        for i <- 1..3 do
          {:ok, signal} =
            Signal.new(%{
              type: "test.signal.#{i}",
              source: "/test",
              data: %{value: i}
            })

          signal
        end

      {:ok, recorded_signals} = Bus.publish(bus, signals)

      for _ <- 1..3 do
        assert_receive {:signal, %Signal{}}
      end

      signal_ids = Enum.map(recorded_signals, & &1.id)

      bus_state = Bus.whereis(bus) |> elem(1) |> :sys.get_state()
      subscription = Map.get(bus_state.subscriptions, subscription_id)
      :ok = GenServer.call(subscription.persistence_pid, {:ack, signal_ids})

      Process.sleep(50)

      checkpoint_key = "#{bus}:#{subscription_id}"
      {:ok, checkpoint} = ETSAdapter.get_checkpoint(checkpoint_key, journal_pid)

      highest_timestamp =
        signal_ids
        |> Enum.map(&ID.extract_timestamp/1)
        |> Enum.max()

      assert checkpoint == highest_timestamp
    end

    test "reconnect replays signals newer than millisecond checkpoint", %{bus: bus} do
      parent = self()

      start_client = fn tag ->
        spawn(fn ->
          receive_loop = fn receive_loop ->
            receive do
              {:signal, signal} ->
                send(parent, {tag, signal})
                receive_loop.(receive_loop)
            end
          end

          receive_loop.(receive_loop)
        end)
      end

      old_client = start_client.(:old_client_signal)
      on_exit(fn -> if Process.alive?(old_client), do: Process.exit(old_client, :kill) end)

      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.signal",
          persistent?: true,
          retry_interval: 1000,
          dispatch: {:pid, target: old_client}
        )

      {:ok, signal1} = Signal.new("test.signal", %{value: 1}, source: "/test")
      signal1_id = signal1.id
      {:ok, [recorded1]} = Bus.publish(bus, [signal1])
      assert_receive {:old_client_signal, %Signal{id: ^signal1_id}}
      assert :ok = Bus.ack(bus, subscription_id, recorded1.id)

      Process.exit(old_client, :kill)
      Process.sleep(50)

      {:ok, signal2} = Signal.new("test.signal", %{value: 2}, source: "/test")
      signal2_id = signal2.id
      {:ok, _} = Bus.publish(bus, [signal2])

      new_client = start_client.(:new_client_signal)
      on_exit(fn -> if Process.alive?(new_client), do: Process.exit(new_client, :kill) end)

      assert {:ok, _checkpoint} = Bus.reconnect(bus, subscription_id, new_client)
      assert_receive {:new_client_signal, %Signal{id: ^signal2_id}}, 1000
      refute_receive {:new_client_signal, %Signal{id: ^signal1_id}}, 100
    end

    test "reconnect does not deadlock under concurrent bus activity", %{bus: bus} do
      old_client =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn -> if Process.alive?(old_client), do: Process.exit(old_client, :kill) end)

      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.signal", persistent?: true, dispatch: {:pid, target: old_client})

      {:ok, signal} = Signal.new("test.signal", %{value: 1}, source: "/test")
      {:ok, _recorded} = Bus.publish(bus, [signal])

      new_client =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn -> if Process.alive?(new_client), do: Process.exit(new_client, :kill) end)

      reconnect_task = Task.async(fn -> Bus.reconnect(bus, subscription_id, new_client) end)
      snapshot_task = Task.async(fn -> Bus.snapshot_list(bus) end)

      assert {:ok, _checkpoint} = Task.await(reconnect_task, 1_000)
      assert is_list(Task.await(snapshot_task, 1_000))
    end

    test "reconnect replaces persistent client monitor reference", %{bus: bus} do
      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.**", persistent?: true, dispatch: {:pid, target: self()})

      bus_state = Bus.whereis(bus) |> elem(1) |> :sys.get_state()
      subscription = Map.get(bus_state.subscriptions, subscription_id)
      persistent_pid = subscription.persistence_pid
      initial_state = :sys.get_state(persistent_pid)
      initial_monitor_ref = initial_state.client_monitor_ref

      assert is_reference(initial_monitor_ref)
      initial_monitors = Process.info(persistent_pid, :monitors) |> elem(1)
      assert {:process, self()} in initial_monitors

      new_client =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      assert {:ok, _checkpoint} = Bus.reconnect(bus, subscription_id, new_client)
      Process.sleep(25)

      reconnected_state = :sys.get_state(persistent_pid)
      assert reconnected_state.client_pid == new_client
      assert reconnected_state.client_monitor_ref != initial_monitor_ref

      monitors = Process.info(persistent_pid, :monitors) |> elem(1)
      assert {:process, new_client} in monitors
      refute {:process, self()} in monitors

      Process.exit(new_client, :kill)
    end

    test "unsubscribe terminates persistent subscription process", %{bus: bus} do
      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.**", persistent?: true, dispatch: {:pid, target: self()})

      bus_state = Bus.whereis(bus) |> elem(1) |> :sys.get_state()
      subscription = Map.get(bus_state.subscriptions, subscription_id)
      persistent_pid = subscription.persistence_pid
      assert Process.alive?(persistent_pid)

      assert :ok = Bus.unsubscribe(bus, subscription_id)

      Process.sleep(25)
      refute Process.alive?(persistent_pid)
    end

    test "unsubscribe keeps checkpoint and dlq when delete_persistence is false", %{
      bus: bus,
      journal_pid: journal_pid
    } do
      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.**", persistent?: true, dispatch: {:pid, target: self()})

      {:ok, signal} =
        Signal.new(%{
          type: "test.signal",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, [recorded_signal]} = Bus.publish(bus, [signal])
      assert_receive {:signal, %Signal{type: "test.signal"}}
      :ok = Bus.ack(bus, subscription_id, recorded_signal.id)

      :ok = Process.sleep(25)

      {:ok, _dlq_id} =
        ETSAdapter.put_dlq_entry(subscription_id, signal, :forced_test_failure, %{}, journal_pid)

      checkpoint_key = "#{bus}:#{subscription_id}"
      assert {:ok, _checkpoint} = ETSAdapter.get_checkpoint(checkpoint_key, journal_pid)
      assert {:ok, [_entry]} = ETSAdapter.get_dlq_entries(subscription_id, journal_pid)

      assert :ok = Bus.unsubscribe(bus, subscription_id, delete_persistence: false)

      assert {:ok, _checkpoint} = ETSAdapter.get_checkpoint(checkpoint_key, journal_pid)
      assert {:ok, [_entry]} = ETSAdapter.get_dlq_entries(subscription_id, journal_pid)
    end

    test "unsubscribe removes checkpoint and dlq when delete_persistence is true", %{
      bus: bus,
      journal_pid: journal_pid
    } do
      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.**", persistent?: true, dispatch: {:pid, target: self()})

      {:ok, signal} =
        Signal.new(%{
          type: "test.signal",
          source: "/test",
          data: %{value: 2}
        })

      {:ok, [recorded_signal]} = Bus.publish(bus, [signal])
      assert_receive {:signal, %Signal{type: "test.signal"}}
      :ok = Bus.ack(bus, subscription_id, recorded_signal.id)

      :ok = Process.sleep(25)

      {:ok, _dlq_id} =
        ETSAdapter.put_dlq_entry(subscription_id, signal, :forced_test_failure, %{}, journal_pid)

      checkpoint_key = "#{bus}:#{subscription_id}"
      assert {:ok, _checkpoint} = ETSAdapter.get_checkpoint(checkpoint_key, journal_pid)
      assert {:ok, [_entry]} = ETSAdapter.get_dlq_entries(subscription_id, journal_pid)

      assert :ok = Bus.unsubscribe(bus, subscription_id, delete_persistence: true)

      assert {:error, :not_found} = ETSAdapter.get_checkpoint(checkpoint_key, journal_pid)
      assert {:ok, []} = ETSAdapter.get_dlq_entries(subscription_id, journal_pid)
    end

    test "bus ack returns error for invalid ack argument", %{bus: bus} do
      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.**", persistent?: true, dispatch: {:pid, target: self()})

      {:ok, signal} =
        Signal.new(%{
          type: "test.signal",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, [_recorded_signal]} = Bus.publish(bus, [signal])
      assert_receive {:signal, %Signal{type: "test.signal"}}

      assert {:error, :invalid_ack_argument} = Bus.ack(bus, subscription_id, :invalid)
    end

    test "bus ack returns error for unknown signal log id", %{bus: bus} do
      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.**", persistent?: true, dispatch: {:pid, target: self()})

      {:ok, signal} =
        Signal.new(%{
          type: "test.signal",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, [_recorded_signal]} = Bus.publish(bus, [signal])
      assert_receive {:signal, %Signal{type: "test.signal"}}

      unknown_signal_log_id = ID.generate!()

      assert {:error, {:unknown_signal_log_id, ^unknown_signal_log_id}} =
               Bus.ack(bus, subscription_id, unknown_signal_log_id)
    end

    test "bus ack returns error for malformed signal log id and keeps processes alive", %{
      bus: bus
    } do
      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.**", persistent?: true, dispatch: {:pid, target: self()})

      {:ok, signal} =
        Signal.new(%{
          type: "test.signal",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, [_recorded_signal]} = Bus.publish(bus, [signal])
      assert_receive {:signal, %Signal{type: "test.signal"}}

      {:ok, bus_pid} = Bus.whereis(bus)
      bus_state = :sys.get_state(bus_pid)
      subscription = Map.fetch!(bus_state.subscriptions, subscription_id)

      assert {:error, {:invalid_signal_log_id, "not-a-uuid"}} =
               Bus.ack(bus, subscription_id, "not-a-uuid")

      assert Process.alive?(bus_pid)
      assert Process.alive?(subscription.persistence_pid)
    end

    test "bus ack supports list of signal ids", %{bus: bus, journal_pid: journal_pid} do
      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.**", persistent?: true, dispatch: {:pid, target: self()})

      signals =
        for i <- 1..2 do
          {:ok, signal} =
            Signal.new(%{
              type: "test.signal.#{i}",
              source: "/test",
              data: %{value: i}
            })

          signal
        end

      {:ok, recorded_signals} = Bus.publish(bus, signals)

      for _ <- 1..2 do
        assert_receive {:signal, %Signal{}}
      end

      signal_ids = Enum.map(recorded_signals, & &1.id)
      assert :ok = Bus.ack(bus, subscription_id, signal_ids)

      Process.sleep(25)
      checkpoint_key = "#{bus}:#{subscription_id}"
      {:ok, checkpoint} = ETSAdapter.get_checkpoint(checkpoint_key, journal_pid)

      expected_checkpoint =
        signal_ids
        |> Enum.map(&ID.extract_timestamp/1)
        |> Enum.max()

      assert checkpoint == expected_checkpoint
    end

    test "bus ack list returns error for mixed known and unknown ids", %{
      bus: bus,
      journal_pid: journal_pid
    } do
      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.**", persistent?: true, dispatch: {:pid, target: self()})

      signals =
        for i <- 1..2 do
          {:ok, signal} =
            Signal.new(%{
              type: "test.signal.#{i}",
              source: "/test",
              data: %{value: i}
            })

          signal
        end

      {:ok, recorded_signals} = Bus.publish(bus, signals)

      for _ <- 1..2 do
        assert_receive {:signal, %Signal{}}
      end

      unknown_signal_log_id = ID.generate!()
      [known_signal_log_id | _] = Enum.map(recorded_signals, & &1.id)

      assert {:error, {:unknown_signal_log_id, ^unknown_signal_log_id}} =
               Bus.ack(bus, subscription_id, [known_signal_log_id, unknown_signal_log_id])

      checkpoint_key = "#{bus}:#{subscription_id}"
      assert {:error, :not_found} = ETSAdapter.get_checkpoint(checkpoint_key, journal_pid)
    end

    test "signal_batch returns queue_full explicitly when capacity is exceeded", %{bus: bus} do
      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.**",
          persistent?: true,
          max_in_flight: 1,
          max_pending: 1,
          dispatch: {:pid, target: self()}
        )

      {:ok, bus_pid} = Bus.whereis(bus)
      bus_state = :sys.get_state(bus_pid)
      subscription = Map.fetch!(bus_state.subscriptions, subscription_id)

      {:ok, signal1} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 1}})
      {:ok, signal2} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 2}})
      {:ok, signal3} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 3}})

      signal_log_id1 = ID.generate!()
      signal_log_id2 = ID.generate!()
      signal_log_id3 = ID.generate!()

      assert {:error, :queue_full} =
               GenServer.call(subscription.persistence_pid, {
                 :signal_batch,
                 [
                   {signal_log_id1, signal1},
                   {signal_log_id2, signal2},
                   {signal_log_id3, signal3}
                 ]
               })

      assert_receive {:signal, %Signal{type: "test.signal"}}, 300

      persistent_state = :sys.get_state(subscription.persistence_pid)
      assert Map.has_key?(persistent_state.in_flight_signals, signal_log_id1)
      assert Map.has_key?(persistent_state.pending_signals, signal_log_id2)
      refute Map.has_key?(persistent_state.in_flight_signals, signal_log_id3)
      refute Map.has_key?(persistent_state.pending_signals, signal_log_id3)
    end
  end

  describe "backward compatibility without journal adapter" do
    setup do
      bus_name = :"test_bus_no_journal_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Bus, name: bus_name})
      {:ok, bus: bus_name}
    end

    test "persistent subscription works with in-memory checkpoints", %{bus: bus} do
      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.**", persistent?: true, dispatch: {:pid, target: self()})

      {:ok, signal} =
        Signal.new(%{
          type: "test.signal",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, [recorded_signal]} = Bus.publish(bus, [signal])

      assert_receive {:signal, %Signal{type: "test.signal"}}

      :ok = Bus.ack(bus, subscription_id, recorded_signal.id)

      bus_state = Bus.whereis(bus) |> elem(1) |> :sys.get_state()
      subscription = Map.get(bus_state.subscriptions, subscription_id)
      persistent_state = :sys.get_state(subscription.persistence_pid)

      assert persistent_state.checkpoint > 0
      assert persistent_state.journal_adapter == nil
    end

    test "subscription and publish work without journal adapter", %{bus: bus} do
      {:ok, _subscription_id} =
        Bus.subscribe(bus, "test.**", persistent?: true, dispatch: {:pid, target: self()})

      {:ok, signal} =
        Signal.new(%{
          type: "test.event",
          source: "/test",
          data: %{foo: "bar"}
        })

      {:ok, _} = Bus.publish(bus, [signal])

      assert_receive {:signal, %Signal{type: "test.event", data: %{foo: "bar"}}}
    end
  end

  describe "max_attempts and DLQ" do
    setup do
      {:ok, journal_pid} = ETSAdapter.start_link("test_dlq_journal_")
      bus_name = :"test_bus_dlq_#{:erlang.unique_integer([:positive])}"

      start_supervised!(
        {Bus, name: bus_name, journal_adapter: ETSAdapter, journal_pid: journal_pid}
      )

      # Create a dead PID for failing dispatch
      {:ok, dead_pid} = Task.start(fn -> :ok end)
      Process.sleep(10)

      {:ok, bus: bus_name, journal_pid: journal_pid, dead_pid: dead_pid}
    end

    test "signal moves to DLQ after max_attempts failures", %{
      bus: bus,
      journal_pid: journal_pid,
      dead_pid: dead_pid
    } do
      # Subscribe with a dispatch that always fails (dead pid)
      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.**",
          persistent?: true,
          max_attempts: 3,
          retry_interval: 10,
          dispatch: {:pid, target: dead_pid}
        )

      {:ok, signal} =
        Signal.new(%{
          type: "test.signal",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, [_recorded_signal]} = Bus.publish(bus, [signal])

      # Wait for retries to be exhausted
      Process.sleep(200)

      # Check that the signal is in the DLQ
      {:ok, dlq_entries} = ETSAdapter.get_dlq_entries(subscription_id, journal_pid)
      assert length(dlq_entries) == 1

      [dlq_entry] = dlq_entries
      assert dlq_entry.signal.type == "test.signal"
      assert dlq_entry.metadata.attempt_count == 3
    end

    test "retry telemetry is emitted on dispatch failure", %{bus: bus, dead_pid: dead_pid} do
      test_pid = self()

      :telemetry.attach(
        "test-retry-handler",
        [:jido, :signal, :subscription, :dispatch, :retry],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:retry_event, measurements, metadata})
        end,
        nil
      )

      {:ok, _subscription_id} =
        Bus.subscribe(bus, "test.**",
          persistent?: true,
          max_attempts: 3,
          retry_interval: 10,
          dispatch: {:pid, target: dead_pid}
        )

      {:ok, signal} =
        Signal.new(%{
          type: "test.retry",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, [_recorded_signal]} = Bus.publish(bus, [signal])

      # Should receive at least one retry event (attempts 1 and 2 before DLQ on 3)
      assert_receive {:retry_event, %{attempt: 1}, %{subscription_id: _, signal_id: _}}, 500

      :telemetry.detach("test-retry-handler")
    end

    test "DLQ telemetry is emitted after max_attempts", %{bus: bus, dead_pid: dead_pid} do
      test_pid = self()

      :telemetry.attach(
        "test-dlq-handler",
        [:jido, :signal, :subscription, :dlq],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:dlq_event, metadata})
        end,
        nil
      )

      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.**",
          persistent?: true,
          max_attempts: 2,
          retry_interval: 10,
          dispatch: {:pid, target: dead_pid}
        )

      {:ok, signal} =
        Signal.new(%{
          type: "test.dlq",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, [_recorded_signal]} = Bus.publish(bus, [signal])

      assert_receive {:dlq_event, %{subscription_id: ^subscription_id, attempts: 2}}, 500

      :telemetry.detach("test-dlq-handler")
    end

    test "no further retries after signal moves to DLQ", %{bus: bus, dead_pid: dead_pid} do
      test_pid = self()
      retry_count = :counters.new(1, [:atomics])

      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.**",
          persistent?: true,
          max_attempts: 2,
          retry_interval: 10,
          dispatch: {:pid, target: dead_pid}
        )

      handler_id = "test-no-more-retries-handler-#{subscription_id}"

      :telemetry.attach(
        handler_id,
        [:jido, :signal, :subscription, :dispatch, :retry],
        fn _event, _measurements, metadata, config ->
          # Only count retries for our subscription
          if metadata.subscription_id == config.subscription_id do
            :counters.add(config.counter, 1, 1)
            send(config.test_pid, :retry_event)
          end
        end,
        %{subscription_id: subscription_id, counter: retry_count, test_pid: test_pid}
      )

      {:ok, signal} =
        Signal.new(%{
          type: "test.no.more.retries",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, [_recorded_signal]} = Bus.publish(bus, [signal])

      # Wait for DLQ
      Process.sleep(200)

      # Count retries - should be exactly 1 (first failure, then DLQ on second)
      count = :counters.get(retry_count, 1)
      assert count == 1, "Expected exactly 1 retry, got #{count}"

      :telemetry.detach(handler_id)
    end

    test "custom max_attempts is respected", %{
      bus: bus,
      journal_pid: journal_pid,
      dead_pid: dead_pid
    } do
      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.**",
          persistent?: true,
          max_attempts: 5,
          retry_interval: 10,
          dispatch: {:pid, target: dead_pid}
        )

      {:ok, signal} =
        Signal.new(%{
          type: "test.custom.attempts",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, [_recorded_signal]} = Bus.publish(bus, [signal])

      # Wait for all retries to be exhausted
      Process.sleep(300)

      {:ok, dlq_entries} = ETSAdapter.get_dlq_entries(subscription_id, journal_pid)
      assert length(dlq_entries) == 1

      [dlq_entry] = dlq_entries
      assert dlq_entry.metadata.attempt_count == 5
    end

    test "successful dispatch clears attempt counter", %{bus: bus} do
      # Use a working dispatch (pid)
      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.**",
          persistent?: true,
          max_attempts: 3,
          dispatch: {:pid, target: self()}
        )

      {:ok, signal} =
        Signal.new(%{
          type: "test.success",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, [recorded_signal]} = Bus.publish(bus, [signal])

      assert_receive {:signal, %Signal{type: "test.success"}}

      # Check that attempts map is empty after success
      bus_state = Bus.whereis(bus) |> elem(1) |> :sys.get_state()
      subscription = Map.get(bus_state.subscriptions, subscription_id)
      persistent_state = :sys.get_state(subscription.persistence_pid)

      # Ack the signal
      :ok = Bus.ack(bus, subscription_id, recorded_signal.id)

      # Attempts should be empty
      assert persistent_state.attempts == %{}
    end
  end
end
