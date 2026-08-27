defmodule Jido.Signal.Bus.InstanceIsolationTest do
  use JidoSignalTest.Case, async: true

  alias Jido.Signal.Bus

  setup do
    {:ok, instance1: __MODULE__.First, instance2: __MODULE__.Second}
  end

  test "uses one Registry with a scoped key", %{instance1: instance} do
    bus_name = unique_name("bus")
    {:ok, bus_pid} = Bus.start_link(name: bus_name, jido: instance)

    assert [{^bus_pid, _}] =
             Registry.lookup(Jido.Signal.Registry, {instance, bus_name})
  end

  test "keeps Buses in different instances isolated", context do
    bus_name = :shared_bus_name
    {:ok, bus1} = Bus.start_link(name: bus_name, jido: context.instance1)
    {:ok, bus2} = Bus.start_link(name: bus_name, jido: context.instance2)
    assert bus1 != bus2

    assert {:ok, _id} = Bus.subscribe(bus1, "test.*")
    signal1 = signal("test.event", %{instance: 1})
    assert {:ok, [_record]} = Bus.publish(bus1, [signal1])
    assert_received {:signal, ^signal1}
    refute_received {:signal, _signal}

    assert {:ok, _id} = Bus.subscribe(bus2, "test.*")
    signal2 = signal("test.event", %{instance: 2})
    assert {:ok, [_record]} = Bus.publish(bus2, [signal2])
    assert_received {:signal, ^signal2}
  end

  test "uses the global Registry without an instance" do
    bus_name = unique_name("global-bus")
    {:ok, bus_pid} = Bus.start_link(name: bus_name)
    assert [{^bus_pid, _}] = Registry.lookup(Jido.Signal.Registry, bus_name)
  end

  test "whereis resolves the correct instance", context do
    bus_name = :lookup_test_bus
    {:ok, bus1} = Bus.start_link(name: bus_name, jido: context.instance1)
    {:ok, bus2} = Bus.start_link(name: bus_name, jido: context.instance2)

    assert {:ok, ^bus1} = Bus.whereis(bus_name, jido: context.instance1)
    assert {:ok, ^bus2} = Bus.whereis(bus_name, jido: context.instance2)
    assert {:error, :not_found} = Bus.whereis(bus_name)
  end

  test "uses scoped child IDs", %{instance1: instance1, instance2: instance2} do
    assert %{id: {:shared_bus, ^instance1}} =
             Bus.child_spec(name: :shared_bus, jido: instance1)

    assert %{id: {:shared_bus, ^instance2}} =
             Bus.child_spec(name: :shared_bus, jido: instance2)
  end
end
