defmodule Jido.Signal.BusInstanceIsolationTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias Jido.Signal.Instance
  alias Jido.Signal.Names

  setup do
    instance1 = __MODULE__.First
    instance2 = __MODULE__.Second

    {:ok, sup1} = Instance.start_link(name: instance1)
    {:ok, sup2} = Instance.start_link(name: instance2)

    on_exit(fn ->
      stop_supervisor(sup1)
      stop_supervisor(sup2)
    end)

    {:ok, instance1: instance1, instance2: instance2}
  end

  test "uses the instance Registry", %{instance1: instance} do
    bus_name = "bus-#{System.unique_integer([:positive])}"
    {:ok, bus_pid} = Bus.start_link(name: bus_name, jido: instance)

    assert [{^bus_pid, _}] = Registry.lookup(Names.registry(jido: instance), bus_name)
  end

  test "keeps Buses in different instances isolated", context do
    bus_name = :shared_bus_name
    {:ok, bus1} = Bus.start_link(name: bus_name, jido: context.instance1)
    {:ok, bus2} = Bus.start_link(name: bus_name, jido: context.instance2)
    assert bus1 != bus2

    assert {:ok, _id} = Bus.subscribe(bus1, "test.*")
    signal1 = Signal.new!("test.event", %{instance: 1}, source: "/test")
    assert {:ok, [_record]} = Bus.publish(bus1, [signal1])
    assert_receive {:signal, ^signal1}
    refute_receive {:signal, _signal}, 20

    assert {:ok, _id} = Bus.subscribe(bus2, "test.*")
    signal2 = Signal.new!("test.event", %{instance: 2}, source: "/test")
    assert {:ok, [_record]} = Bus.publish(bus2, [signal2])
    assert_receive {:signal, ^signal2}
  end

  test "uses the global Registry without an instance" do
    bus_name = "global-bus-#{System.unique_integer([:positive])}"
    {:ok, bus_pid} = Bus.start_link(name: bus_name)
    assert [{^bus_pid, _}] = Registry.lookup(Jido.Signal.Registry, bus_name)
  end

  test "whereis resolves the correct instance", context do
    bus_name = :lookup_test_bus
    {:ok, bus1} = Bus.start_link(name: bus_name, jido: context.instance1)
    {:ok, bus2} = Bus.start_link(name: bus_name, jido: context.instance2)

    assert {:ok, ^bus1} = Bus.whereis(bus_name, jido: context.instance1)
    assert {:ok, ^bus2} = Bus.whereis(bus_name, jido: context.instance2)
  end

  defp stop_supervisor(supervisor) do
    try do
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor, :normal, 100)
    catch
      :exit, _reason -> :ok
    end
  end
end
