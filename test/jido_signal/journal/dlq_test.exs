defmodule Jido.Signal.Journal.DLQTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Journal.Adapters.ETS
  alias Jido.Signal.Journal.Adapters.InMemory

  defp create_test_signal do
    {:ok, signal} =
      Signal.new(%{
        type: "test.signal",
        source: "/test",
        data: %{value: 42}
      })

    signal
  end

  describe "ETS adapter DLQ operations" do
    setup do
      {:ok, pid} = ETS.init()

      on_exit(fn ->
        if Process.alive?(pid), do: ETS.cleanup(pid)
      end)

      {:ok, pid: pid}
    end

    test "put_dlq_entry/5 creates entry with all fields", %{pid: pid} do
      signal = create_test_signal()
      subscription_id = "sub_123"
      reason = {:error, :max_attempts_exceeded}
      metadata = %{attempt_count: 3}

      assert {:ok, entry_id} = ETS.put_dlq_entry(subscription_id, signal, reason, metadata, pid)
      assert is_binary(entry_id)

      {:ok, [entry]} = ETS.get_dlq_entries(subscription_id, pid)
      assert entry.id == entry_id
      assert entry.subscription_id == subscription_id
      assert entry.signal == signal
      assert entry.reason == reason
      assert entry.metadata == metadata
      assert %DateTime{} = entry.inserted_at
    end

    test "get_dlq_entries/2 returns entries for subscription", %{pid: pid} do
      signal1 = create_test_signal()
      signal2 = create_test_signal()
      subscription_id = "sub_456"

      {:ok, _} = ETS.put_dlq_entry(subscription_id, signal1, :error1, %{}, pid)
      {:ok, _} = ETS.put_dlq_entry(subscription_id, signal2, :error2, %{}, pid)

      {:ok, entries} = ETS.get_dlq_entries(subscription_id, pid)
      assert length(entries) == 2
    end

    test "get_dlq_entries/2 returns empty list for unknown subscription", %{pid: pid} do
      {:ok, entries} = ETS.get_dlq_entries("nonexistent", pid)
      assert entries == []
    end

    test "delete_dlq_entry/2 removes specific entry", %{pid: pid} do
      signal = create_test_signal()
      subscription_id = "sub_789"

      {:ok, entry_id} = ETS.put_dlq_entry(subscription_id, signal, :error, %{}, pid)
      {:ok, [_entry]} = ETS.get_dlq_entries(subscription_id, pid)

      assert :ok = ETS.delete_dlq_entry(entry_id, pid)
      {:ok, entries} = ETS.get_dlq_entries(subscription_id, pid)
      assert entries == []
    end

    test "clear_dlq/2 removes all entries for subscription", %{pid: pid} do
      signal = create_test_signal()
      sub_a = "sub_a"
      sub_b = "sub_b"

      {:ok, _} = ETS.put_dlq_entry(sub_a, signal, :error1, %{}, pid)
      {:ok, _} = ETS.put_dlq_entry(sub_a, signal, :error2, %{}, pid)
      {:ok, _} = ETS.put_dlq_entry(sub_b, signal, :error3, %{}, pid)

      assert :ok = ETS.clear_dlq(sub_a, pid)

      {:ok, entries_a} = ETS.get_dlq_entries(sub_a, pid)
      {:ok, entries_b} = ETS.get_dlq_entries(sub_b, pid)

      assert entries_a == []
      assert length(entries_b) == 1
    end

    test "entries are ordered by inserted_at", %{pid: pid} do
      signal = create_test_signal()
      subscription_id = "sub_ordered"

      {:ok, id1} = ETS.put_dlq_entry(subscription_id, signal, :error1, %{}, pid)
      Process.sleep(10)
      {:ok, id2} = ETS.put_dlq_entry(subscription_id, signal, :error2, %{}, pid)
      Process.sleep(10)
      {:ok, id3} = ETS.put_dlq_entry(subscription_id, signal, :error3, %{}, pid)

      {:ok, entries} = ETS.get_dlq_entries(subscription_id, pid)
      ids = Enum.map(entries, & &1.id)
      assert ids == [id1, id2, id3]
    end
  end

  describe "InMemory adapter DLQ operations" do
    setup do
      {:ok, pid} = InMemory.init()
      {:ok, pid: pid}
    end

    test "put_dlq_entry/5 creates entry with all fields", %{pid: pid} do
      signal = create_test_signal()
      subscription_id = "sub_123"
      reason = {:error, :max_attempts_exceeded}
      metadata = %{attempt_count: 3}

      assert {:ok, entry_id} =
               InMemory.put_dlq_entry(subscription_id, signal, reason, metadata, pid)

      assert is_binary(entry_id)

      {:ok, [entry]} = InMemory.get_dlq_entries(subscription_id, pid)
      assert entry.id == entry_id
      assert entry.subscription_id == subscription_id
      assert entry.signal == signal
      assert entry.reason == reason
      assert entry.metadata == metadata
      assert %DateTime{} = entry.inserted_at
    end

    test "get_dlq_entries/2 returns entries for subscription", %{pid: pid} do
      signal1 = create_test_signal()
      signal2 = create_test_signal()
      subscription_id = "sub_456"

      {:ok, _} = InMemory.put_dlq_entry(subscription_id, signal1, :error1, %{}, pid)
      {:ok, _} = InMemory.put_dlq_entry(subscription_id, signal2, :error2, %{}, pid)

      {:ok, entries} = InMemory.get_dlq_entries(subscription_id, pid)
      assert length(entries) == 2
    end

    test "get_dlq_entries/2 returns empty list for unknown subscription", %{pid: pid} do
      {:ok, entries} = InMemory.get_dlq_entries("nonexistent", pid)
      assert entries == []
    end

    test "delete_dlq_entry/2 removes specific entry", %{pid: pid} do
      signal = create_test_signal()
      subscription_id = "sub_789"

      {:ok, entry_id} = InMemory.put_dlq_entry(subscription_id, signal, :error, %{}, pid)
      {:ok, [_entry]} = InMemory.get_dlq_entries(subscription_id, pid)

      assert :ok = InMemory.delete_dlq_entry(entry_id, pid)
      {:ok, entries} = InMemory.get_dlq_entries(subscription_id, pid)
      assert entries == []
    end

    test "clear_dlq/2 removes all entries for subscription", %{pid: pid} do
      signal = create_test_signal()
      sub_a = "sub_a"
      sub_b = "sub_b"

      {:ok, _} = InMemory.put_dlq_entry(sub_a, signal, :error1, %{}, pid)
      {:ok, _} = InMemory.put_dlq_entry(sub_a, signal, :error2, %{}, pid)
      {:ok, _} = InMemory.put_dlq_entry(sub_b, signal, :error3, %{}, pid)

      assert :ok = InMemory.clear_dlq(sub_a, pid)

      {:ok, entries_a} = InMemory.get_dlq_entries(sub_a, pid)
      {:ok, entries_b} = InMemory.get_dlq_entries(sub_b, pid)

      assert entries_a == []
      assert length(entries_b) == 1
    end

    test "entries are ordered by inserted_at", %{pid: pid} do
      signal = create_test_signal()
      subscription_id = "sub_ordered"

      {:ok, id1} = InMemory.put_dlq_entry(subscription_id, signal, :error1, %{}, pid)
      Process.sleep(10)
      {:ok, id2} = InMemory.put_dlq_entry(subscription_id, signal, :error2, %{}, pid)
      Process.sleep(10)
      {:ok, id3} = InMemory.put_dlq_entry(subscription_id, signal, :error3, %{}, pid)

      {:ok, entries} = InMemory.get_dlq_entries(subscription_id, pid)
      ids = Enum.map(entries, & &1.id)
      assert ids == [id1, id2, id3]
    end
  end
end

defmodule Jido.Signal.Journal.DLQMnesiaTest do
  use ExUnit.Case, async: false

  alias Jido.Signal
  alias Jido.Signal.Journal.Adapters.Mnesia
  alias Jido.Signal.Journal.Adapters.Mnesia.Tables

  @compile {:no_warn_undefined, :mnesia}
  @moduletag :mnesia

  defp create_test_signal do
    {:ok, signal} =
      Signal.new(%{
        type: "test.signal",
        source: "/test",
        data: %{value: 42}
      })

    signal
  end

  setup_all do
    :mnesia.stop()
    File.rm_rf("Mnesia.nonode@nohost")
    :mnesia.create_schema([node()])
    :mnesia.start()

    :ok = Mnesia.init()

    on_exit(fn ->
      :mnesia.stop()
      File.rm_rf("Mnesia.nonode@nohost")
    end)

    :ok
  end

  setup do
    :mnesia.clear_table(Tables.DLQ)
    :ok
  end

  test "put_dlq_entry/5 creates entry with all fields" do
    signal = create_test_signal()
    subscription_id = "sub_mnesia_123"
    reason = {:error, :max_attempts_exceeded}
    metadata = %{attempt_count: 3}

    assert {:ok, entry_id} = Mnesia.put_dlq_entry(subscription_id, signal, reason, metadata, nil)
    assert is_binary(entry_id)

    {:ok, [entry]} = Mnesia.get_dlq_entries(subscription_id, nil)
    assert entry.id == entry_id
    assert entry.subscription_id == subscription_id
    assert entry.signal == signal
    assert entry.reason == reason
    assert entry.metadata == metadata
    assert %DateTime{} = entry.inserted_at
  end

  test "get_dlq_entries/2 returns entries for subscription" do
    signal1 = create_test_signal()
    signal2 = create_test_signal()
    subscription_id = "sub_mnesia_456"

    {:ok, _} = Mnesia.put_dlq_entry(subscription_id, signal1, :error1, %{}, nil)
    {:ok, _} = Mnesia.put_dlq_entry(subscription_id, signal2, :error2, %{}, nil)

    {:ok, entries} = Mnesia.get_dlq_entries(subscription_id, nil)
    assert length(entries) == 2
  end

  test "get_dlq_entries/2 returns empty list for unknown subscription" do
    {:ok, entries} = Mnesia.get_dlq_entries("nonexistent", nil)
    assert entries == []
  end

  test "delete_dlq_entry/2 removes specific entry" do
    signal = create_test_signal()
    subscription_id = "sub_mnesia_789"

    {:ok, entry_id} = Mnesia.put_dlq_entry(subscription_id, signal, :error, %{}, nil)
    {:ok, [_entry]} = Mnesia.get_dlq_entries(subscription_id, nil)

    assert :ok = Mnesia.delete_dlq_entry(entry_id, nil)
    {:ok, entries} = Mnesia.get_dlq_entries(subscription_id, nil)
    assert entries == []
  end

  test "clear_dlq/2 removes all entries for subscription" do
    signal = create_test_signal()
    sub_a = "sub_mnesia_a"
    sub_b = "sub_mnesia_b"

    {:ok, _} = Mnesia.put_dlq_entry(sub_a, signal, :error1, %{}, nil)
    {:ok, _} = Mnesia.put_dlq_entry(sub_a, signal, :error2, %{}, nil)
    {:ok, _} = Mnesia.put_dlq_entry(sub_b, signal, :error3, %{}, nil)

    assert :ok = Mnesia.clear_dlq(sub_a, nil)

    {:ok, entries_a} = Mnesia.get_dlq_entries(sub_a, nil)
    {:ok, entries_b} = Mnesia.get_dlq_entries(sub_b, nil)

    assert entries_a == []
    assert length(entries_b) == 1
  end

  test "entries are ordered by inserted_at" do
    signal = create_test_signal()
    subscription_id = "sub_mnesia_ordered"

    {:ok, id1} = Mnesia.put_dlq_entry(subscription_id, signal, :error1, %{}, nil)
    Process.sleep(10)
    {:ok, id2} = Mnesia.put_dlq_entry(subscription_id, signal, :error2, %{}, nil)
    Process.sleep(10)
    {:ok, id3} = Mnesia.put_dlq_entry(subscription_id, signal, :error3, %{}, nil)

    {:ok, entries} = Mnesia.get_dlq_entries(subscription_id, nil)
    ids = Enum.map(entries, & &1.id)
    assert ids == [id1, id2, id3]
  end
end
