defmodule Jido.Signal.Journal.Adapters.ETSDLQQueryTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Journal.Adapters.ETS

  defp signal(type) do
    Signal.new!(%{
      type: type,
      source: "/test",
      data: %{value: type}
    })
  end

  setup do
    {:ok, pid} = ETS.init()

    on_exit(fn ->
      if Process.alive?(pid), do: ETS.cleanup(pid)
    end)

    {:ok, pid: pid}
  end

  test "get_dlq_entries/3 supports bounded reads without cross-subscription leakage", %{pid: pid} do
    sub_a = "sub-a-#{System.unique_integer([:positive])}"
    sub_b = "sub-b-#{System.unique_integer([:positive])}"

    {:ok, _} = ETS.put_dlq_entry(sub_a, signal("test.a.1"), :error, %{idx: 1}, pid)
    {:ok, _} = ETS.put_dlq_entry(sub_b, signal("test.b.1"), :error, %{idx: 1}, pid)
    {:ok, _} = ETS.put_dlq_entry(sub_a, signal("test.a.2"), :error, %{idx: 2}, pid)
    {:ok, _} = ETS.put_dlq_entry(sub_a, signal("test.a.3"), :error, %{idx: 3}, pid)

    {:ok, limited_entries} = ETS.get_dlq_entries(sub_a, pid, limit: 2)

    assert length(limited_entries) == 2
    assert Enum.all?(limited_entries, &(&1.subscription_id == sub_a))
    assert Enum.map(limited_entries, & &1.metadata.idx) == [1, 2]
  end

  test "clear_dlq/3 clears only matching subscription entries", %{pid: pid} do
    sub_a = "sub-a-#{System.unique_integer([:positive])}"
    sub_b = "sub-b-#{System.unique_integer([:positive])}"

    {:ok, _} = ETS.put_dlq_entry(sub_a, signal("test.a"), :error, %{}, pid)
    {:ok, _} = ETS.put_dlq_entry(sub_b, signal("test.b"), :error, %{}, pid)

    assert :ok = ETS.clear_dlq(sub_a, pid, [])

    {:ok, entries_a} = ETS.get_dlq_entries(sub_a, pid)
    {:ok, entries_b} = ETS.get_dlq_entries(sub_b, pid)

    assert entries_a == []
    assert length(entries_b) == 1
  end

  test "clear_dlq/3 honors limit while preserving later entries", %{pid: pid} do
    sub_a = "sub-a-#{System.unique_integer([:positive])}"
    sub_b = "sub-b-#{System.unique_integer([:positive])}"

    {:ok, _} = ETS.put_dlq_entry(sub_a, signal("test.a.1"), :error, %{idx: 1}, pid)
    {:ok, _} = ETS.put_dlq_entry(sub_a, signal("test.a.2"), :error, %{idx: 2}, pid)
    {:ok, _} = ETS.put_dlq_entry(sub_a, signal("test.a.3"), :error, %{idx: 3}, pid)
    {:ok, _} = ETS.put_dlq_entry(sub_b, signal("test.b.1"), :error, %{idx: 1}, pid)

    assert :ok = ETS.clear_dlq(sub_a, pid, limit: 2)

    {:ok, entries_a} = ETS.get_dlq_entries(sub_a, pid)
    {:ok, entries_b} = ETS.get_dlq_entries(sub_b, pid)

    assert Enum.map(entries_a, & &1.metadata.idx) == [3]
    assert Enum.map(entries_b, & &1.metadata.idx) == [1]
  end

  test "get_dlq_entries/3 tolerates stale subscription index references", %{pid: pid} do
    subscription_id = "sub-stale-#{System.unique_integer([:positive])}"
    {:ok, entry_id} = ETS.put_dlq_entry(subscription_id, signal("test.stale"), :error, %{}, pid)

    adapter = :sys.get_state(pid)

    assert [{^subscription_id, ^entry_id}] =
             :ets.lookup(adapter.dlq_subscription_index_table, subscription_id)

    :sys.replace_state(pid, fn adapter_state ->
      :ets.delete(adapter_state.dlq_table, entry_id)
      adapter_state
    end)

    {:ok, []} = ETS.get_dlq_entries(subscription_id, pid)

    assert [{^subscription_id, ^entry_id}] =
             :ets.lookup(adapter.dlq_subscription_index_table, subscription_id)
  end
end
