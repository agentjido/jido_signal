defmodule Jido.Signal.BusInstanceIsolationTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias Jido.Signal.Instance
  alias Jido.Signal.Names

  setup do
    # Create unique instance names for test isolation
    instance1 = :"TestInstance1_#{System.unique_integer([:positive])}"
    instance2 = :"TestInstance2_#{System.unique_integer([:positive])}"

    {:ok, _sup1} = Instance.start_link(name: instance1)
    {:ok, _sup2} = Instance.start_link(name: instance2)

    on_exit(fn ->
      _ = Instance.stop(instance1)
      _ = Instance.stop(instance2)
    end)

    {:ok, instance1: instance1, instance2: instance2}
  end

  describe "Bus with instance isolation" do
    test "bus uses instance-scoped registry when jido option provided", %{instance1: instance} do
      bus_name = :"bus_#{System.unique_integer()}"

      {:ok, bus_pid} =
        Bus.start_link(
          name: bus_name,
          jido: instance
        )

      # Bus should be registered in the instance's registry
      instance_registry = Names.registry(jido: instance)
      bus_name_str = Atom.to_string(bus_name)

      assert [{^bus_pid, _}] = Registry.lookup(instance_registry, bus_name_str)
    end

    test "buses in different instances are isolated", %{
      instance1: instance1,
      instance2: instance2
    } do
      bus_name = :shared_bus_name

      {:ok, bus1} =
        Bus.start_link(
          name: bus_name,
          jido: instance1
        )

      {:ok, bus2} =
        Bus.start_link(
          name: bus_name,
          jido: instance2
        )

      # Different processes with same name in different instances
      assert bus1 != bus2

      # Subscribe to each bus
      {:ok, _sub1} = Bus.subscribe(bus1, "test.*", dispatch: {:pid, target: self()})
      {:ok, _sub2} = Bus.subscribe(bus2, "test.*", dispatch: {:pid, target: self()})

      # Create and publish signal to bus1
      {:ok, signal} = Signal.new("test.event", %{instance: 1}, source: "/test")
      {:ok, _} = Bus.publish(bus1, [signal])

      # Should receive only from bus1
      assert_receive {:signal, received_signal}
      assert received_signal.data.instance == 1

      # Publish to bus2
      {:ok, signal2} = Signal.new("test.event", %{instance: 2}, source: "/test")
      {:ok, _} = Bus.publish(bus2, [signal2])

      # Should receive from bus2
      assert_receive {:signal, received_signal2}
      assert received_signal2.data.instance == 2
    end

    test "bus without jido option uses global registry" do
      bus_name = :"global_bus_#{System.unique_integer()}"

      {:ok, bus_pid} = Bus.start_link(name: bus_name)

      # Should be accessible via global registry
      bus_name_str = Atom.to_string(bus_name)
      assert [{^bus_pid, _}] = Registry.lookup(Jido.Signal.Registry, bus_name_str)
    end

    test "whereis resolves bus from correct instance", %{
      instance1: instance1,
      instance2: instance2
    } do
      bus_name = :lookup_test_bus

      {:ok, bus1} = Bus.start_link(name: bus_name, jido: instance1)
      {:ok, bus2} = Bus.start_link(name: bus_name, jido: instance2)

      # Lookup should find the correct bus per instance
      assert {:ok, ^bus1} = Bus.whereis(bus_name, jido: instance1)
      assert {:ok, ^bus2} = Bus.whereis(bus_name, jido: instance2)

      # They should be different processes
      assert bus1 != bus2
    end
  end
end
