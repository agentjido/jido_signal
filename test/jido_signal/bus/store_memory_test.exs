defmodule Jido.Signal.Bus.Store.MemoryTest do
  use ExUnit.Case, async: true

  alias Jido.Signal.Bus.Store.Memory

  test "keeps a bounded, ordered record log" do
    assert {:ok, state} = Memory.init(max_records: 2)

    records = [
      %{"format_version" => 1, "id" => "one", "cursor" => 1},
      %{"format_version" => 1, "id" => "two", "cursor" => 2},
      %{"format_version" => 1, "id" => "three", "cursor" => 3}
    ]

    assert {:ok, state} = Memory.append(records, state)
    assert {:ok, [second, third]} = Memory.read([after_cursor: -1], state)
    assert second["id"] == "two"
    assert third["id"] == "three"
    assert {:ok, [^third]} = Memory.read([after_cursor: 2], state)
  end

  test "keeps checkpoints and dead-letter entries by subscription" do
    assert {:ok, state} = Memory.init([])
    assert {:ok, state} = Memory.put_checkpoint("bus:sub", 4, state)
    assert {:ok, 4} = Memory.get_checkpoint("bus:sub", state)

    entry = %{"format_version" => 1, "id" => "entry-one"}
    assert {:ok, state} = Memory.put_dlq("sub", entry, state)
    assert {:ok, [^entry]} = Memory.list_dlq("sub", state)

    assert {:ok, state} = Memory.delete_dlq("sub", ["entry-one"], state)
    assert {:ok, []} = Memory.list_dlq("sub", state)

    assert {:ok, state} = Memory.delete_checkpoint("bus:sub", state)
    assert {:ok, nil} = Memory.get_checkpoint("bus:sub", state)
  end

  test "rejects an invalid record bound" do
    assert {:error, {:invalid_option, :max_records}} = Memory.init(max_records: 0)
  end
end
