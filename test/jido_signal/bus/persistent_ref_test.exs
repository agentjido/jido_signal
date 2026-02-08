defmodule Jido.Signal.Bus.PersistentRefTest do
  use ExUnit.Case, async: true

  alias Jido.Signal.Bus.PersistentRef
  alias Jido.Signal.Bus.PersistentSubscription

  test "builds stable via target for bus/subscription pair" do
    ref = PersistentRef.new(:bus_a, "sub-1")

    assert %PersistentRef{bus_name: :bus_a, subscription_id: "sub-1"} = ref
    assert ref.via == PersistentSubscription.via_tuple(:bus_a, "sub-1")
    assert PersistentRef.target(ref) == ref.via
  end

  test "derives from legacy subscription shape without persistence_ref" do
    pid = self()

    subscription = %{
      id: "sub-legacy",
      persistent?: true,
      persistence_pid: pid
    }

    ref = PersistentRef.from_subscription(subscription, :bus_legacy)

    assert %PersistentRef{} = ref
    assert ref.pid == pid
    assert PersistentRef.target(ref) == ref.via
  end
end
