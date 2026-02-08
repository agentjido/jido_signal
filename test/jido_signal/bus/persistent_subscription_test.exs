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

  defmodule BlockingAckDispatchAdapter do
    @behaviour Jido.Signal.Dispatch.Adapter

    @impl true
    def validate_opts(opts), do: {:ok, opts}

    @impl true
    def deliver(signal, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      signal_id = signal.id
      send(test_pid, {:ack_leak_dispatch_started, self(), signal_id})

      receive do
        {:release_ack_leak_dispatch, ^signal_id} -> :ok
      end
    end
  end

  defmodule FlakyDLQWriteAdapter do
    def init do
      test_pid = Application.fetch_env!(:jido_signal, :flaky_dlq_test_pid)

      Agent.start_link(fn ->
        %{
          test_pid: test_pid,
          checkpoints: %{},
          dlq_entries: %{},
          dlq_attempts_by_log_id: %{}
        }
      end)
    end

    def put_signal(_signal, _pid), do: :ok
    def get_signal(_signal_id, _pid), do: {:error, :not_found}
    def put_cause(_cause_id, _effect_id, _pid), do: :ok
    def get_effects(_signal_id, _pid), do: {:ok, MapSet.new()}
    def get_cause(_signal_id, _pid), do: {:error, :not_found}
    def put_conversation(_conversation_id, _signal_id, _pid), do: :ok
    def get_conversation(_conversation_id, _pid), do: {:ok, MapSet.new()}

    def put_checkpoint(checkpoint_key, checkpoint, pid) do
      Agent.update(pid, fn state ->
        %{state | checkpoints: Map.put(state.checkpoints, checkpoint_key, checkpoint)}
      end)

      :ok
    end

    def get_checkpoint(checkpoint_key, pid) do
      case Agent.get(pid, fn state -> Map.get(state.checkpoints, checkpoint_key) end) do
        nil -> {:error, :not_found}
        checkpoint -> {:ok, checkpoint}
      end
    end

    def delete_checkpoint(checkpoint_key, pid) do
      Agent.update(pid, fn state ->
        %{state | checkpoints: Map.delete(state.checkpoints, checkpoint_key)}
      end)

      :ok
    end

    def put_dlq_entry(subscription_id, signal, reason, metadata, pid) do
      signal_log_id = Map.fetch!(metadata, :signal_log_id)

      {attempt, test_pid} =
        Agent.get_and_update(pid, fn state ->
          attempt = Map.get(state.dlq_attempts_by_log_id, signal_log_id, 0) + 1

          {
            {attempt, state.test_pid},
            %{
              state
              | dlq_attempts_by_log_id:
                  Map.put(state.dlq_attempts_by_log_id, signal_log_id, attempt)
            }
          }
        end)

      if attempt == 1 do
        send(
          test_pid,
          {:dlq_write_attempt, signal_log_id, attempt, {:error, :transient_dlq_failure}}
        )

        {:error, :transient_dlq_failure}
      else
        entry = %{
          id: "dlq-#{System.unique_integer([:positive])}",
          subscription_id: subscription_id,
          signal: signal,
          reason: reason,
          metadata: metadata,
          inserted_at: DateTime.utc_now()
        }

        Agent.update(pid, fn state ->
          entries = Map.update(state.dlq_entries, subscription_id, [entry], &[entry | &1])
          %{state | dlq_entries: entries}
        end)

        send(test_pid, {:dlq_write_attempt, signal_log_id, attempt, {:ok, entry.id}})
        {:ok, entry.id}
      end
    end

    def get_dlq_entries(subscription_id, pid) do
      entries =
        Agent.get(pid, fn state ->
          state.dlq_entries
          |> Map.get(subscription_id, [])
          |> Enum.reverse()
        end)

      {:ok, entries}
    end

    def delete_dlq_entry(entry_id, pid) do
      Agent.update(pid, fn state ->
        updated_entries =
          Map.new(state.dlq_entries, fn {subscription_id, entries} ->
            {subscription_id, Enum.reject(entries, &(&1.id == entry_id))}
          end)

        %{state | dlq_entries: updated_entries}
      end)

      :ok
    end

    def clear_dlq(subscription_id, pid) do
      Agent.update(pid, fn state ->
        %{state | dlq_entries: Map.delete(state.dlq_entries, subscription_id)}
      end)

      :ok
    end
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

    test "persistent subscription recovers after process restart without resubscribe", %{
      bus: bus
    } do
      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.recover.**", persistent?: true, dispatch: {:pid, target: self()})

      {:ok, bus_pid} = Bus.whereis(bus)
      bus_state = :sys.get_state(bus_pid)
      subscription = Map.get(bus_state.subscriptions, subscription_id)
      old_persistent_pid = subscription.persistence_pid

      down_ref = Process.monitor(old_persistent_pid)
      Process.exit(old_persistent_pid, :kill)
      assert_receive {:DOWN, ^down_ref, :process, ^old_persistent_pid, _reason}

      new_persistent_pid = wait_for_persistent_pid(bus, subscription_id, old_persistent_pid)
      assert is_pid(new_persistent_pid)
      assert new_persistent_pid != old_persistent_pid

      {:ok, signal} =
        Signal.new(%{
          type: "test.recover.signal",
          source: "/test",
          data: %{value: 42}
        })

      {:ok, [recorded]} = Bus.publish(bus, [signal])
      assert_receive {:signal, %Signal{type: "test.recover.signal"}}, 1_000
      assert :ok = Bus.ack(bus, subscription_id, recorded.id)
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

    test "acked_signals markers are cleared after in-flight dispatch completes", %{bus: bus} do
      {:ok, bus_pid} = Bus.whereis(bus)

      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.**",
          persistent?: true,
          dispatch: {BlockingAckDispatchAdapter, [test_pid: self()]},
          max_in_flight: 50
        )

      signals =
        for i <- 1..20 do
          Signal.new!(%{
            type: "test.ack.leak",
            source: "/test",
            data: %{value: i}
          })
        end

      {:ok, recorded_signals} = Bus.publish(bus, signals)

      signal_id_to_log_id =
        Map.new(recorded_signals, fn recorded ->
          {recorded.signal.id, recorded.id}
        end)

      started_dispatches =
        Enum.map(1..20, fn _ ->
          assert_receive {:ack_leak_dispatch_started, dispatch_pid, signal_id}, 1_000
          {dispatch_pid, signal_id}
        end)

      Enum.each(started_dispatches, fn {_dispatch_pid, signal_id} ->
        log_id = Map.fetch!(signal_id_to_log_id, signal_id)
        assert :ok = Bus.ack(bus, subscription_id, log_id)
      end)

      persistent_state = persistent_state(bus_pid, subscription_id)
      assert map_size(persistent_state.acked_signals) == 20

      Enum.each(started_dispatches, fn {dispatch_pid, signal_id} ->
        send(dispatch_pid, {:release_ack_leak_dispatch, signal_id})
      end)

      assert_persistent_state(bus_pid, subscription_id, fn state ->
        map_size(state.acked_signals) == 0 and
          map_size(state.in_flight_signals) == 0 and
          map_size(state.pending_signals) == 0
      end)
    end

    test "failed DLQ write is retried and signal is not dropped" do
      Application.put_env(:jido_signal, :flaky_dlq_test_pid, self())

      on_exit(fn ->
        Application.delete_env(:jido_signal, :flaky_dlq_test_pid)
      end)

      bus_name = :"test_bus_flaky_dlq_#{:erlang.unique_integer([:positive])}"

      start_supervised!({Bus, name: bus_name, journal_adapter: FlakyDLQWriteAdapter})

      {:ok, bus_pid} = Bus.whereis(bus_name)

      {:ok, subscription_id} =
        Bus.subscribe(bus_name, "test.**",
          persistent?: true,
          max_attempts: 1,
          retry_interval: 10,
          dispatch: {AlwaysFailDispatchAdapter, []}
        )

      signal = Signal.new!(type: "test.flaky.dlq", source: "/test", data: %{value: 1})

      {:ok, [_recorded_signal]} = Bus.publish(bus_name, [signal])

      assert_receive {:dlq_write_attempt, signal_log_id, 1, {:error, :transient_dlq_failure}},
                     2_000

      assert_receive {:dlq_write_attempt, ^signal_log_id, 2, {:ok, _dlq_id}}, 2_000

      assert {:ok, dlq_entries} = Bus.dlq_entries(bus_name, subscription_id)
      assert length(dlq_entries) == 1
      [entry] = dlq_entries
      assert entry.metadata.signal_log_id == signal_log_id
      assert entry.metadata.attempt_count == 1

      assert_persistent_state(bus_pid, subscription_id, fn state ->
        map_size(state.dlq_pending) == 0 and
          map_size(state.pending_signals) == 0 and
          map_size(state.attempts) == 0
      end)
    end
  end

  defp persistent_state(bus_pid, subscription_id) do
    bus_state = :sys.get_state(bus_pid)
    subscription = Map.fetch!(bus_state.subscriptions, subscription_id)
    :sys.get_state(subscription.persistence_pid)
  end

  defp assert_persistent_state(bus_pid, subscription_id, predicate, attempts \\ 100)

  defp assert_persistent_state(_bus_pid, _subscription_id, _predicate, 0) do
    flunk("persistent subscription state did not converge")
  end

  defp assert_persistent_state(bus_pid, subscription_id, predicate, attempts) do
    state = persistent_state(bus_pid, subscription_id)

    if predicate.(state) do
      :ok
    else
      receive do
      after
        10 -> assert_persistent_state(bus_pid, subscription_id, predicate, attempts - 1)
      end
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

  defp wait_for_persistent_pid(bus, subscription_id, old_pid, attempts \\ 100)

  defp wait_for_persistent_pid(_bus, _subscription_id, _old_pid, 0),
    do: flunk("persistent subscription did not restart")

  defp wait_for_persistent_pid(bus, subscription_id, old_pid, attempts) do
    case PersistentSubscription.whereis(bus, subscription_id) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        receive do
        after
          10 -> wait_for_persistent_pid(bus, subscription_id, old_pid, attempts - 1)
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
