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

    {:ok, sup1} = Instance.start_link(name: instance1)
    {:ok, sup2} = Instance.start_link(name: instance2)

    on_exit(fn ->
      # Gracefully stop if still alive, ignore errors
      try do
        if Process.alive?(sup1), do: Supervisor.stop(sup1, :normal, 100)
      catch
        :exit, _ -> :ok
      end

      try do
        if Process.alive?(sup2), do: Supervisor.stop(sup2, :normal, 100)
      catch
        :exit, _ -> :ok
      end
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

    test "partitioned buses remain isolated across instances", %{
      instance1: instance1,
      instance2: instance2
    } do
      bus_name = :partitioned_shared_bus

      {:ok, bus1} = Bus.start_link(name: bus_name, jido: instance1, partition_count: 2)
      {:ok, bus2} = Bus.start_link(name: bus_name, jido: instance2, partition_count: 2)

      assert bus1 != bus2

      {:ok, _sub1} = Bus.subscribe(bus1, "partitioned.*", dispatch: {:pid, target: self()})
      {:ok, _sub2} = Bus.subscribe(bus2, "partitioned.*", dispatch: {:pid, target: self()})

      {:ok, signal1} = Signal.new("partitioned.event", %{instance: 1}, source: "/test")
      {:ok, signal2} = Signal.new("partitioned.event", %{instance: 2}, source: "/test")

      {:ok, _} = Bus.publish(bus1, [signal1])
      assert_receive {:signal, received_1}
      assert received_1.data.instance == 1

      {:ok, _} = Bus.publish(bus2, [signal2])
      assert_receive {:signal, received_2}
      assert received_2.data.instance == 2

      reg1 = Names.registry(jido: instance1)
      reg2 = Names.registry(jido: instance2)

      partition_key_0 = {:partition, bus_name, 0}
      partition_key_1 = {:partition, bus_name, 1}

      assert [{pid_1_0, _}] = Registry.lookup(reg1, partition_key_0)
      assert [{pid_1_1, _}] = Registry.lookup(reg1, partition_key_1)
      assert [{pid_2_0, _}] = Registry.lookup(reg2, partition_key_0)
      assert [{pid_2_1, _}] = Registry.lookup(reg2, partition_key_1)

      assert pid_1_0 != pid_2_0
      assert pid_1_1 != pid_2_1
    end
  end
end
