defmodule JidoTest.Signal.Bus.PersistentSubscriptionCheckpointTest do
  use ExUnit.Case, async: false

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias Jido.Signal.Bus.PersistentSubscription
  alias Jido.Signal.Bus.Subscriber
  alias Jido.Signal.ID
  alias Jido.Signal.Journal.Adapters.ETS, as: ETSAdapter

  @moduletag :capture_log

  defmodule BlockingCheckpointLoadAdapter do
    def start_link(test_pid) when is_pid(test_pid) do
      Agent.start_link(fn -> %{test_pid: test_pid, checkpoints: %{}} end)
    end

    def get_checkpoint(checkpoint_key, pid) do
      test_pid = Agent.get(pid, & &1.test_pid)
      send(test_pid, {:checkpoint_load_started, checkpoint_key, self()})

      receive do
        {:release_checkpoint_load, ^checkpoint_key, checkpoint} ->
          {:ok, checkpoint}
      end
    end

    def put_checkpoint(checkpoint_key, checkpoint, pid) do
      Agent.update(pid, fn state ->
        %{state | checkpoints: Map.put(state.checkpoints, checkpoint_key, checkpoint)}
      end)

      :ok
    end
  end

  defmodule AlwaysFailDispatchAdapter do
    @behaviour Jido.Signal.Dispatch.Adapter

    @impl true
    def validate_opts(opts), do: {:ok, opts}

    @impl true
    def deliver(_signal, _opts), do: {:error, :forced_dispatch_failure}
  end

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

      {:ok, [recorded2]} = Bus.publish(bus, [signal2])
      assert_receive {:signal, %Signal{type: "test.signal.two"}}
      :ok = Bus.ack(bus, subscription_id, recorded2.id)

      checkpoint_key = "#{bus}:#{subscription_id}"
      {:ok, checkpoint_before} = ETSAdapter.get_checkpoint(checkpoint_key, journal_pid)
      assert checkpoint_before > 0

      bus_state = Bus.whereis(bus) |> elem(1) |> :sys.get_state()
      subscription = Map.get(bus_state.subscriptions, subscription_id)
      assert subscription.persistence_pid != nil

      old_persistent_pid = subscription.persistence_pid
      down_ref = Process.monitor(old_persistent_pid)
      GenServer.stop(old_persistent_pid, :normal)
      assert_receive {:DOWN, ^down_ref, :process, ^old_persistent_pid, _reason}

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

      checkpoint_key = "#{bus}:#{subscription_id}"
      {:ok, checkpoint} = ETSAdapter.get_checkpoint(checkpoint_key, journal_pid)

      highest_timestamp =
        signal_ids
        |> Enum.map(&ID.extract_timestamp/1)
        |> Enum.max()

      assert checkpoint == highest_timestamp
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

  describe "reconnect replay checkpoint semantics" do
    test "replays missed signals using log entry ids after checkpoint" do
      bus_name = :"test_bus_replay_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Bus, name: bus_name})
      {:ok, bus_pid} = Bus.whereis(bus_name)

      {:ok, first_signal} =
        Signal.new(%{
          type: "test.replay",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, [first_recorded]} = Bus.publish(bus_name, [first_signal])
      checkpoint = ID.extract_timestamp(first_recorded.id)

      publish_after_checkpoint = fn publish_after_checkpoint ->
        {:ok, signal} =
          Signal.new(%{
            type: "test.replay",
            source: "/test",
            data: %{value: 2}
          })

        {:ok, [recorded]} = Bus.publish(bus_name, [signal])

        if ID.extract_timestamp(recorded.id) > checkpoint do
          :ok
        else
          publish_after_checkpoint.(publish_after_checkpoint)
        end
      end

      :ok = publish_after_checkpoint.(publish_after_checkpoint)

      bus_state = :sys.get_state(bus_pid)

      missed_signals =
        bus_state.log
        |> Enum.sort_by(fn {log_id, _signal} -> log_id end)
        |> Enum.filter(fn {log_id, signal} ->
          ID.extract_timestamp(log_id) > checkpoint and signal.type == "test.replay"
        end)
        |> Enum.map(fn {_log_id, signal} -> signal end)

      old_client =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      subscription = %Subscriber{
        id: "replay-sub",
        path: "test.replay",
        dispatch: {:pid, target: old_client, delivery_mode: :async},
        persistent?: true,
        persistence_pid: nil,
        created_at: DateTime.utc_now()
      }

      {:ok, pid} =
        PersistentSubscription.start_link(
          id: "replay-sub",
          bus_pid: bus_pid,
          bus_name: bus_name,
          bus_subscription: subscription,
          checkpoint: checkpoint,
          client_pid: old_client
        )

      GenServer.cast(pid, {:reconnect, self(), missed_signals})

      assert_receive {:signal, %Signal{type: "test.replay", data: %{value: 2}}}, 500
      send(old_client, :stop)
    end

    test "does not replay entries whose log timestamp equals checkpoint" do
      bus_name = :"test_bus_replay_equal_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Bus, name: bus_name})

      {:ok, subscription_id} =
        Bus.subscribe(bus_name, "test.replay.equal",
          persistent?: true,
          dispatch: {:pid, target: self(), delivery_mode: :async}
        )

      signal = Signal.new!(type: "test.replay.equal", source: "/test", data: %{value: 1})
      {:ok, [recorded]} = Bus.publish(bus_name, [signal])
      assert_receive {:signal, %Signal{type: "test.replay.equal"}}, 1_000
      :ok = Bus.ack(bus_name, subscription_id, recorded.id)

      assert {:ok, _checkpoint} = Bus.reconnect(bus_name, subscription_id, self())
      refute_receive {:signal, %Signal{type: "test.replay.equal"}}, 200
    end

    test "reconnect tolerates malformed log ids without crashing" do
      bus_name = :"test_bus_replay_malformed_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Bus, name: bus_name})
      {:ok, bus_pid} = Bus.whereis(bus_name)

      {:ok, subscription_id} =
        Bus.subscribe(bus_name, "test.replay.malformed",
          persistent?: true,
          dispatch: {:pid, target: self(), delivery_mode: :async}
        )

      malformed_signal =
        Signal.new!(type: "test.replay.malformed", source: "/test", data: %{bad: true})

      :sys.replace_state(bus_pid, fn state ->
        %{state | log: Map.put(state.log, "not-a-uuid", malformed_signal)}
      end)

      assert {:ok, _checkpoint} = Bus.reconnect(bus_name, subscription_id, self())
    end
  end

  describe "start_link option validation" do
    test "returns explicit error when bus_subscription is missing" do
      subscription_id = "missing-subscription-#{System.unique_integer([:positive])}"

      assert {:error, {:missing_option, :bus_subscription}} =
               PersistentSubscription.start_link(
                 id: subscription_id,
                 bus_pid: self(),
                 bus_name: :validation_bus,
                 client_pid: self()
               )
    end

    test "allows nil client_pid for disconnected persistent subscribers" do
      subscription_id = "nil-client-#{System.unique_integer([:positive])}"

      subscription = %Subscriber{
        id: subscription_id,
        path: "test.validation",
        dispatch: {:pid, target: self(), delivery_mode: :async},
        persistent?: true,
        persistence_pid: nil,
        created_at: DateTime.utc_now()
      }

      assert {:ok, pid} =
               PersistentSubscription.start_link(
                 id: subscription_id,
                 bus_pid: self(),
                 bus_name: :validation_bus,
                 bus_subscription: subscription,
                 client_pid: nil
               )

      state = :sys.get_state(pid)
      assert state.client_pid == nil

      GenServer.stop(pid, :normal)
    end
  end

  describe "deferred checkpoint loading" do
    test "start_link returns before checkpoint load I/O completes" do
      subscription_id = "deferred-load-#{System.unique_integer([:positive])}"
      bus_name = :deferred_checkpoint_bus
      checkpoint_key = "#{bus_name}:#{subscription_id}"
      {:ok, journal_pid} = BlockingCheckpointLoadAdapter.start_link(self())

      subscription = %Subscriber{
        id: subscription_id,
        path: "test.deferred",
        dispatch: {:pid, target: self(), delivery_mode: :async},
        persistent?: true,
        persistence_pid: nil,
        created_at: DateTime.utc_now()
      }

      task =
        Task.async(fn ->
          PersistentSubscription.start_link(
            id: subscription_id,
            bus_pid: self(),
            bus_name: bus_name,
            bus_subscription: subscription,
            checkpoint: 0,
            journal_adapter: BlockingCheckpointLoadAdapter,
            journal_pid: journal_pid
          )
        end)

      assert_receive {:checkpoint_load_started, ^checkpoint_key, loader_pid}, 1_000

      try do
        assert {:ok, {:ok, pid}} = Task.yield(task, 200)
        send(loader_pid, {:release_checkpoint_load, checkpoint_key, 0})
        stop_subscription(pid)
      after
        send(loader_pid, {:release_checkpoint_load, checkpoint_key, 0})
        Task.shutdown(task, :brutal_kill)
      end
    end

    test "checkpoint value is applied after deferred load continues" do
      subscription_id = "deferred-apply-#{System.unique_integer([:positive])}"
      bus_name = :deferred_checkpoint_apply_bus
      checkpoint_key = "#{bus_name}:#{subscription_id}"
      {:ok, journal_pid} = BlockingCheckpointLoadAdapter.start_link(self())

      subscription = %Subscriber{
        id: subscription_id,
        path: "test.deferred.apply",
        dispatch: {:pid, target: self(), delivery_mode: :async},
        persistent?: true,
        persistence_pid: nil,
        created_at: DateTime.utc_now()
      }

      assert {:ok, pid} =
               PersistentSubscription.start_link(
                 id: subscription_id,
                 bus_pid: self(),
                 bus_name: bus_name,
                 bus_subscription: subscription,
                 checkpoint: 0,
                 journal_adapter: BlockingCheckpointLoadAdapter,
                 journal_pid: journal_pid
               )

      assert_receive {:checkpoint_load_started, ^checkpoint_key, loader_pid}, 1_000
      send(loader_pid, {:release_checkpoint_load, checkpoint_key, 42})
      assert_checkpoint(pid, 42)

      stop_subscription(pid)
    end
  end

  describe "max_attempts and DLQ" do
    setup do
      {:ok, journal_pid} = ETSAdapter.start_link("test_dlq_journal_")
      bus_name = :"test_bus_dlq_#{:erlang.unique_integer([:positive])}"

      start_supervised!(
        {Bus, name: bus_name, journal_adapter: ETSAdapter, journal_pid: journal_pid}
      )

      {:ok, bus: bus_name, journal_pid: journal_pid}
    end

    test "signal moves to DLQ after max_attempts failures", %{bus: bus, journal_pid: journal_pid} do
      test_pid = self()
      handler_id = "test-signal-to-dlq-handler-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:jido, :signal, :subscription, :dlq],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:dlq_event, metadata})
        end,
        nil
      )

      # Subscribe with a dispatch that always fails (dead pid)
      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.**",
          persistent?: true,
          max_attempts: 3,
          retry_interval: 10,
          dispatch: {AlwaysFailDispatchAdapter, []}
        )

      {:ok, signal} =
        Signal.new(%{
          type: "test.signal",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, [_recorded_signal]} = Bus.publish(bus, [signal])

      assert_receive {:dlq_event, %{subscription_id: ^subscription_id, attempts: 3}}, 3_000

      # Check that the signal is in the DLQ
      {:ok, dlq_entries} = ETSAdapter.get_dlq_entries(subscription_id, journal_pid)
      assert length(dlq_entries) == 1

      [dlq_entry] = dlq_entries
      assert dlq_entry.signal.type == "test.signal"
      assert dlq_entry.metadata.attempt_count == 3
      :telemetry.detach(handler_id)
    end

    test "retry telemetry is emitted on dispatch failure", %{bus: bus} do
      test_pid = self()
      retry_handler_id = "test-retry-handler-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        retry_handler_id,
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
          dispatch: {AlwaysFailDispatchAdapter, []}
        )

      {:ok, signal} =
        Signal.new(%{
          type: "test.retry",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, [_recorded_signal]} = Bus.publish(bus, [signal])

      # Should receive at least one retry event (attempts 1 and 2 before DLQ on 3)
      assert_receive {:retry_event, %{attempt: 1}, %{subscription_id: _, signal_id: _}}, 2_000

      :telemetry.detach(retry_handler_id)
    end

    test "DLQ telemetry is emitted after max_attempts", %{bus: bus} do
      test_pid = self()
      dlq_handler_id = "test-dlq-handler-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        dlq_handler_id,
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
          dispatch: {AlwaysFailDispatchAdapter, []}
        )

      {:ok, signal} =
        Signal.new(%{
          type: "test.dlq",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, [_recorded_signal]} = Bus.publish(bus, [signal])

      assert_receive {:dlq_event, %{subscription_id: ^subscription_id, attempts: 2}}, 2_000

      :telemetry.detach(dlq_handler_id)
    end

    test "no further retries after signal moves to DLQ", %{bus: bus} do
      test_pid = self()
      retry_count = :counters.new(1, [:atomics])

      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.**",
          persistent?: true,
          max_attempts: 2,
          retry_interval: 10,
          dispatch: {AlwaysFailDispatchAdapter, []}
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

      assert_receive :retry_event, 3_000

      dlq_handler_id = "test-no-more-retries-dlq-handler-#{subscription_id}"

      :telemetry.attach(
        dlq_handler_id,
        [:jido, :signal, :subscription, :dlq],
        fn _event, _measurements, metadata, config ->
          if metadata.subscription_id == config.subscription_id do
            send(config.test_pid, :dlq_event)
          end
        end,
        %{subscription_id: subscription_id, test_pid: test_pid}
      )

      assert_receive :dlq_event, 3_000

      # Count retries - should be exactly 1 (first failure, then DLQ on second)
      count = :counters.get(retry_count, 1)
      assert count == 1, "Expected exactly 1 retry, got #{count}"
      refute_receive :retry_event, 200

      :telemetry.detach(handler_id)
      :telemetry.detach(dlq_handler_id)
    end

    test "custom max_attempts is respected", %{bus: bus, journal_pid: journal_pid} do
      test_pid = self()
      handler_id = "test-custom-attempts-dlq-handler-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:jido, :signal, :subscription, :dlq],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:dlq_event, metadata})
        end,
        nil
      )

      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.**",
          persistent?: true,
          max_attempts: 5,
          retry_interval: 10,
          dispatch: {AlwaysFailDispatchAdapter, []}
        )

      {:ok, signal} =
        Signal.new(%{
          type: "test.custom.attempts",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, [_recorded_signal]} = Bus.publish(bus, [signal])

      assert_receive {:dlq_event, %{subscription_id: ^subscription_id, attempts: 5}}, 5_000

      {:ok, dlq_entries} = ETSAdapter.get_dlq_entries(subscription_id, journal_pid)
      assert length(dlq_entries) == 1

      [dlq_entry] = dlq_entries
      assert dlq_entry.metadata.attempt_count == 5
      :telemetry.detach(handler_id)
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

  defp assert_checkpoint(pid, expected, attempts \\ 100)

  defp assert_checkpoint(_pid, _expected, 0), do: flunk("checkpoint did not converge")

  defp assert_checkpoint(pid, expected, attempts) do
    if :sys.get_state(pid).checkpoint == expected do
      :ok
    else
      receive do
      after
        10 -> assert_checkpoint(pid, expected, attempts - 1)
      end
    end
  end

  defp stop_subscription(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal)
      catch
        :exit, _ -> :ok
      end
    else
      :ok
    end
  end
end
