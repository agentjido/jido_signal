defmodule Jido.Signal.Bus.Store.MemoryTest do
  use ExUnit.Case, async: true

  alias Jido.Signal.Bus.Store.Memory

  test "keeps a bounded ordered record log and its latest cursor" do
    assert {:ok, state} = Memory.init(max_records: 2)
    records = [record(1, "one"), record(2, "two"), record(3, "three")]

    assert {:ok, state} = Memory.append(records, state)
    assert {:ok, [second, third]} = Memory.read([after_cursor: 0], state)
    assert second["id"] == "two"
    assert third["id"] == "three"
    assert {:ok, [^third]} = Memory.read([after_cursor: 2], state)
    assert {:ok, 3} = Memory.latest_cursor(state)
  end

  test "keeps durable subscription definitions in creation order" do
    assert {:ok, state} = Memory.init([])

    assert {:ok, state} =
             Memory.append(
               [record(1, "one"), record(2, "two"), record(3, "three"), record(4, "four")],
               state
             )

    first = subscription("first", "orders.*", 2)
    second = subscription("second", "audit.**", 4)

    assert {:ok, state} = Memory.put_subscription(first, state)
    assert {:ok, state} = Memory.put_subscription(second, state)
    assert {:ok, [^first, ^second]} = Memory.list_subscriptions(state)

    updated = %{first | "cursor" => 3}
    assert {:ok, state} = Memory.put_subscription(updated, state)
    assert {:ok, [^updated, ^second]} = Memory.list_subscriptions(state)

    assert {:ok, state} = Memory.delete_subscription("first", state)
    assert {:ok, [^second]} = Memory.list_subscriptions(state)
  end

  test "does not remove a record that an unacknowledged durable subscription needs" do
    assert {:ok, state} = Memory.init(max_records: 2)
    assert {:ok, state} = Memory.put_subscription(subscription("agent", "orders.*", 0), state)
    assert {:ok, state} = Memory.append([record(1, "one"), record(2, "two")], state)

    assert {:error, {:store_full, ["agent"]}} = Memory.append([record(3, "three")], state)
    assert {:ok, [first, second]} = Memory.read([after_cursor: 0], state)
    assert Enum.map([first, second], & &1["cursor"]) == [1, 2]
    assert {:ok, 2} = Memory.latest_cursor(state)
  end

  test "releases acknowledged records" do
    assert {:ok, state} = Memory.init(max_records: 2)
    definition = subscription("agent", "orders.*", 0)
    assert {:ok, state} = Memory.put_subscription(definition, state)
    assert {:ok, state} = Memory.append([record(1, "one"), record(2, "two")], state)

    assert {:ok, state} = Memory.put_subscription(%{definition | "cursor" => 1}, state)
    assert {:ok, state} = Memory.append([record(3, "three")], state)
    assert {:ok, records} = Memory.read([after_cursor: 0], state)
    assert Enum.map(records, & &1["cursor"]) == [2, 3]
  end

  test "rejects invalid bounds and non-contiguous cursors" do
    assert {:error, {:invalid_option, :max_records}} = Memory.init(max_records: 0)
    assert {:ok, state} = Memory.init([])
    assert {:error, :invalid_record_cursors} = Memory.append([record(2, "two")], state)

    assert {:error, :invalid_subscription_cursor} =
             Memory.put_subscription(subscription("future", "orders.*", 1), state)
  end

  defp record(cursor, id) do
    %{
      "format_version" => 1,
      "id" => id,
      "cursor" => cursor,
      "type" => "orders.created",
      "created_at" => "2026-01-01T00:00:00Z",
      "signal" => %{"id" => id, "type" => "orders.created"}
    }
  end

  defp subscription(id, path, cursor) do
    %{
      "format_version" => 1,
      "id" => id,
      "path" => path,
      "cursor" => cursor,
      "created_at" => "2026-01-01T00:00:00Z"
    }
  end
end
