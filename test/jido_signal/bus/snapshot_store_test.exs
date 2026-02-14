defmodule Jido.Signal.Bus.SnapshotStoreTest do
  use ExUnit.Case, async: false

  alias Jido.Signal.Bus.SnapshotStore

  setup do
    unique = System.unique_integer([:positive])
    bus_a = :"snapshot-store-a-#{unique}"
    bus_b = :"snapshot-store-b-#{unique}"
    snapshot_id = "snapshot-#{unique}"

    on_exit(fn ->
      SnapshotStore.delete_bus(bus_a, nil)
      SnapshotStore.delete_bus(bus_b, nil)
    end)

    {:ok, bus_a: bus_a, bus_b: bus_b, snapshot_id: snapshot_id}
  end

  test "get/3 only returns data for the exact bus scope", %{
    bus_a: bus_a,
    bus_b: bus_b,
    snapshot_id: snapshot_id
  } do
    payload = %{bus: :a}
    assert :ok = SnapshotStore.put(bus_a, nil, snapshot_id, payload)

    assert {:ok, ^payload} = SnapshotStore.get(bus_a, nil, snapshot_id)
    assert :error = SnapshotStore.get(bus_b, nil, snapshot_id)
  end

  test "delete/3 only removes data for the exact bus scope", %{
    bus_a: bus_a,
    bus_b: bus_b,
    snapshot_id: snapshot_id
  } do
    payload = %{bus: :a}
    assert :ok = SnapshotStore.put(bus_a, nil, snapshot_id, payload)

    assert :ok = SnapshotStore.delete(bus_b, nil, snapshot_id)
    assert {:ok, ^payload} = SnapshotStore.get(bus_a, nil, snapshot_id)

    assert :ok = SnapshotStore.delete(bus_a, nil, snapshot_id)
    assert :error = SnapshotStore.get(bus_a, nil, snapshot_id)
  end

  test "same snapshot id across buses remains isolated on delete", %{
    bus_a: bus_a,
    bus_b: bus_b,
    snapshot_id: snapshot_id
  } do
    payload_a = %{bus: :a}
    payload_b = %{bus: :b}

    assert :ok = SnapshotStore.put(bus_a, nil, snapshot_id, payload_a)
    assert :ok = SnapshotStore.put(bus_b, nil, snapshot_id, payload_b)

    assert :ok = SnapshotStore.delete(bus_a, nil, snapshot_id)

    assert :error = SnapshotStore.get(bus_a, nil, snapshot_id)
    assert {:ok, ^payload_b} = SnapshotStore.get(bus_b, nil, snapshot_id)
  end
end
