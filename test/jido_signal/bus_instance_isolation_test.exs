defmodule Jido.Signal.BusInstanceIsolationTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias Jido.Signal.Instance
  alias Jido.Signal.Names

  defmodule SupervisorProbeMiddleware do
    use Jido.Signal.Bus.Middleware

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def before_publish(signals, context, test_pid) do
      supervised? = self() in Task.Supervisor.children(context.task_supervisor)
      send(test_pid, {:middleware_supervisor, context.task_supervisor, supervised?})
      {:cont, signals, test_pid}
    end
  end

  setup do
    instance1 = __MODULE__.First
    instance2 = __MODULE__.Second

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
      bus_name = "bus-#{System.unique_integer([:positive])}"

      {:ok, bus_pid} =
        Bus.start_link(
          name: bus_name,
          jido: instance
        )

      # Bus should be registered in the instance's registry
      instance_registry = Names.registry(jido: instance)
      assert [{^bus_pid, _}] = Registry.lookup(instance_registry, bus_name)
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
      bus_name = "global-bus-#{System.unique_integer([:positive])}"

      {:ok, bus_pid} = Bus.start_link(name: bus_name)

      # Should be accessible via global registry
      assert [{^bus_pid, _}] = Registry.lookup(Jido.Signal.Registry, bus_name)
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

    test "instance-scoped bus dispatch works with multi-target dispatch lists", %{
      instance1: instance
    } do
      bus_name = "dispatch-bus-#{System.unique_integer([:positive])}"

      {:ok, bus} = Bus.start_link(name: bus_name, jido: instance)

      dispatch = [
        {:pid, [target: self(), delivery_mode: :async]},
        {:logger, [level: :debug]}
      ]

      {:ok, _sub} = Bus.subscribe(bus, "dispatch.*", dispatch: dispatch)

      {:ok, signal} = Signal.new("dispatch.event", %{ok: true}, source: "/test")
      {:ok, _} = Bus.publish(bus, [signal])

      assert_receive {:signal, received}
      assert received.id == signal.id
      assert received.data == %{ok: true}
    end

    test "middleware callbacks use the instance Task Supervisor", %{instance1: instance} do
      bus_name = "middleware-bus-#{System.unique_integer([:positive])}"

      {:ok, bus} =
        Bus.start_link(
          name: bus_name,
          jido: instance,
          middleware: [{SupervisorProbeMiddleware, self()}]
        )

      {:ok, signal} = Signal.new("middleware.event", %{}, source: "/test")
      assert {:ok, _records} = Bus.publish(bus, [signal])

      expected_supervisor = Names.task_supervisor(jido: instance)
      assert_receive {:middleware_supervisor, ^expected_supervisor, true}
    end
  end
end
