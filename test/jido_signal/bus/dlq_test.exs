defmodule JidoTest.Signal.Bus.DLQTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias Jido.Signal.Journal.Adapters.ETS

  @moduletag :capture_log

  defmodule SlowSuccessAdapter do
    @behaviour Jido.Signal.Dispatch.Adapter

    @impl true
    def validate_opts(opts), do: {:ok, opts}

    @impl true
    def deliver(_signal, opts) do
      Process.sleep(Keyword.get(opts, :sleep_ms, 150))
      :ok
    end
  end

  defp create_test_signal(type \\ "test.signal") do
    {:ok, signal} =
      Signal.new(%{
        type: type,
        source: "/test",
        data: %{value: 42}
      })

    signal
  end

  describe "dlq_entries/2" do
    setup do
      {:ok, journal_pid} = ETS.init()
      bus_name = "dlq-test-bus-#{:erlang.unique_integer([:positive])}"

      start_supervised!({Bus, name: bus_name, journal_adapter: ETS, journal_pid: journal_pid})

      on_exit(fn ->
        if Process.alive?(journal_pid), do: ETS.cleanup(journal_pid)
      end)

      {:ok, bus: bus_name, journal_pid: journal_pid}
    end

    test "returns DLQ entries for a subscription", %{bus: bus, journal_pid: journal_pid} do
      subscription_id = "test_sub_#{:erlang.unique_integer([:positive])}"
      signal = create_test_signal()

      {:ok, _entry_id} =
        ETS.put_dlq_entry(
          subscription_id,
          signal,
          :max_attempts_exceeded,
          %{attempts: 3},
          journal_pid
        )

      {:ok, entries} = Bus.dlq_entries(bus, subscription_id)
      assert length(entries) == 1
      assert hd(entries).signal == signal
    end

    test "returns empty list for subscription with no DLQ entries", %{bus: bus} do
      {:ok, entries} = Bus.dlq_entries(bus, "nonexistent_sub")
      assert entries == []
    end

    test "returns error when no journal adapter configured" do
      bus_name = "no-journal-bus-#{:erlang.unique_integer([:positive])}"
      start_supervised!({Bus, name: bus_name})

      assert {:error, :no_journal_adapter} = Bus.dlq_entries(bus_name, "any_sub")
    end
  end

  describe "redrive_dlq/3" do
    setup do
      {:ok, journal_pid} = ETS.init()
      bus_name = "dlq-redrive-bus-#{:erlang.unique_integer([:positive])}"

      start_supervised!({Bus, name: bus_name, journal_adapter: ETS, journal_pid: journal_pid})

      on_exit(fn ->
        if Process.alive?(journal_pid), do: ETS.cleanup(journal_pid)
      end)

      {:ok, bus: bus_name, journal_pid: journal_pid}
    end

    test "successfully redrives DLQ entries", %{bus: bus, journal_pid: journal_pid} do
      {:ok, subscription_id} = Bus.subscribe(bus, "test.*")
      signal = create_test_signal("test.signal")

      {:ok, _entry_id} =
        ETS.put_dlq_entry(subscription_id, signal, :max_attempts_exceeded, %{}, journal_pid)

      {:ok, result} = Bus.redrive_dlq(bus, subscription_id)

      assert result.succeeded == 1
      assert result.failed == 0

      assert_receive {:signal, %Signal{type: "test.signal"}}

      {:ok, entries} = Bus.dlq_entries(bus, subscription_id)
      assert entries == []
    end

    test "keeps entries in DLQ when clear_on_success is false", %{
      bus: bus,
      journal_pid: journal_pid
    } do
      {:ok, subscription_id} = Bus.subscribe(bus, "test.*")
      signal = create_test_signal("test.signal")

      {:ok, _entry_id} =
        ETS.put_dlq_entry(subscription_id, signal, :max_attempts_exceeded, %{}, journal_pid)

      {:ok, result} = Bus.redrive_dlq(bus, subscription_id, clear_on_success: false)

      assert result.succeeded == 1

      {:ok, entries} = Bus.dlq_entries(bus, subscription_id)
      assert length(entries) == 1
    end

    test "respects limit option", %{bus: bus, journal_pid: journal_pid} do
      {:ok, subscription_id} = Bus.subscribe(bus, "test.*")

      for i <- 1..5 do
        signal = create_test_signal("test.signal.#{i}")
        {:ok, _} = ETS.put_dlq_entry(subscription_id, signal, :error, %{}, journal_pid)
        Process.sleep(10)
      end

      {:ok, result} = Bus.redrive_dlq(bus, subscription_id, limit: 2)

      assert result.succeeded == 2
      assert result.failed == 0

      {:ok, entries} = Bus.dlq_entries(bus, subscription_id)
      assert length(entries) == 3
    end

    test "returns error for non-existent subscription", %{bus: bus, journal_pid: journal_pid} do
      signal = create_test_signal()
      {:ok, _} = ETS.put_dlq_entry("nonexistent_sub", signal, :error, %{}, journal_pid)

      assert {:error, :subscription_not_found} = Bus.redrive_dlq(bus, "nonexistent_sub")
    end

    test "returns error when no journal adapter configured" do
      bus_name = "no-journal-bus-#{:erlang.unique_integer([:positive])}"
      start_supervised!({Bus, name: bus_name})

      assert {:error, :no_journal_adapter} = Bus.redrive_dlq(bus_name, "any_sub")
    end

    test "emits telemetry on redrive", %{bus: bus, journal_pid: journal_pid} do
      {:ok, subscription_id} = Bus.subscribe(bus, "test.*")
      signal = create_test_signal("test.signal")

      {:ok, _} = ETS.put_dlq_entry(subscription_id, signal, :error, %{}, journal_pid)

      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-redrive-#{inspect(ref)}",
        [:jido, :signal, :bus, :dlq, :redrive],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      {:ok, _result} = Bus.redrive_dlq(bus, subscription_id)

      assert_receive {:telemetry, [:jido, :signal, :bus, :dlq, :redrive], measurements, metadata}
      assert measurements.succeeded == 1
      assert measurements.failed == 0
      assert metadata.subscription_id == subscription_id

      :telemetry.detach("test-redrive-#{inspect(ref)}")
    end

    test "redrive does not block unrelated bus calls", %{bus: bus, journal_pid: journal_pid} do
      {:ok, subscription_id} =
        Bus.subscribe(bus, "test.*", dispatch: {SlowSuccessAdapter, [sleep_ms: 250]})

      signal = create_test_signal("test.signal.slow")
      {:ok, _entry_id} = ETS.put_dlq_entry(subscription_id, signal, :error, %{}, journal_pid)

      redrive_task = Task.async(fn -> Bus.redrive_dlq(bus, subscription_id) end)

      started_at = System.monotonic_time(:millisecond)
      snapshots = Bus.snapshot_list(bus)
      duration_ms = System.monotonic_time(:millisecond) - started_at

      assert is_list(snapshots)
      assert duration_ms < 200

      assert {:ok, %{succeeded: 1, failed: 0}} = Task.await(redrive_task, 1_000)
    end
  end

  describe "clear_dlq/2" do
    setup do
      {:ok, journal_pid} = ETS.init()
      bus_name = "dlq-clear-bus-#{:erlang.unique_integer([:positive])}"

      start_supervised!({Bus, name: bus_name, journal_adapter: ETS, journal_pid: journal_pid})

      on_exit(fn ->
        if Process.alive?(journal_pid), do: ETS.cleanup(journal_pid)
      end)

      {:ok, bus: bus_name, journal_pid: journal_pid}
    end

    test "clears all DLQ entries for a subscription", %{bus: bus, journal_pid: journal_pid} do
      subscription_id = "test_sub_#{:erlang.unique_integer([:positive])}"

      for i <- 1..3 do
        signal = create_test_signal("test.signal.#{i}")
        {:ok, _} = ETS.put_dlq_entry(subscription_id, signal, :error, %{}, journal_pid)
      end

      {:ok, entries_before} = Bus.dlq_entries(bus, subscription_id)
      assert length(entries_before) == 3

      assert :ok = Bus.clear_dlq(bus, subscription_id)

      {:ok, entries_after} = Bus.dlq_entries(bus, subscription_id)
      assert entries_after == []
    end

    test "does not affect other subscriptions", %{bus: bus, journal_pid: journal_pid} do
      sub_a = "sub_a_#{:erlang.unique_integer([:positive])}"
      sub_b = "sub_b_#{:erlang.unique_integer([:positive])}"

      signal = create_test_signal()
      {:ok, _} = ETS.put_dlq_entry(sub_a, signal, :error, %{}, journal_pid)
      {:ok, _} = ETS.put_dlq_entry(sub_b, signal, :error, %{}, journal_pid)

      :ok = Bus.clear_dlq(bus, sub_a)

      {:ok, entries_a} = Bus.dlq_entries(bus, sub_a)
      {:ok, entries_b} = Bus.dlq_entries(bus, sub_b)

      assert entries_a == []
      assert length(entries_b) == 1
    end

    test "returns error when no journal adapter configured" do
      bus_name = "no-journal-bus-#{:erlang.unique_integer([:positive])}"
      start_supervised!({Bus, name: bus_name})

      assert {:error, :no_journal_adapter} = Bus.clear_dlq(bus_name, "any_sub")
    end
  end
end
