defmodule Jido.Signal.Bus.SchemaInvariantsTest do
  use ExUnit.Case, async: true

  alias Jido.Signal.Bus.Partition
  alias Jido.Signal.Bus.PersistentSubscription
  alias Jido.Signal.Bus.State, as: BusState
  alias Jido.Signal.Bus.Subscriber

  test "bus state struct requires non-nil router" do
    assert_raise ArgumentError, ~r/router/, fn ->
      struct!(BusState, %{name: :schema_bus})
    end
  end

  test "subscriber defaults created_at to datetime" do
    subscriber = struct!(Subscriber, %{id: "sub", path: "test.*", dispatch: {:pid, self()}})
    assert %DateTime{} = subscriber.created_at
  end

  test "persistent subscription struct requires checkpoint key" do
    assert_raise ArgumentError, ~r/checkpoint_key/, fn ->
      struct!(PersistentSubscription, %{
        id: "sub",
        bus_pid: self(),
        bus_subscription: %Subscriber{id: "sub", path: "test.*", dispatch: {:pid, self()}}
      })
    end
  end

  test "partition struct requires runtime rate-limit state" do
    assert_raise ArgumentError, ~r/(tokens|last_refill)/, fn ->
      struct!(Partition, %{partition_id: 0, bus_name: :schema_bus})
    end
  end
end
