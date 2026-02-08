defmodule Jido.Signal.InstanceTest do
  use ExUnit.Case, async: true

  alias Jido.Signal.Instance
  alias Jido.Signal.Bus
  alias Jido.Signal.Dispatch
  alias Jido.Signal.Names
  alias Jido.Signal

  describe "Names.scoped/2" do
    test "returns default when no jido option" do
      assert Names.registry([]) == Jido.Signal.Registry
      assert Names.task_supervisor([]) == Jido.Signal.TaskSupervisor
      assert Names.supervisor([]) == Jido.Signal.Supervisor
      assert Names.bus_runtime_supervisor([]) == Jido.Signal.Bus.RuntimeSupervisor
    end

    test "returns default when jido is nil" do
      assert Names.registry(jido: nil) == Jido.Signal.Registry
      assert Names.task_supervisor(jido: nil) == Jido.Signal.TaskSupervisor
    end

    test "scopes names when jido instance provided" do
      assert Names.registry(jido: MyApp.Jido) == MyApp.Jido.Signal.Registry
      assert Names.task_supervisor(jido: MyApp.Jido) == MyApp.Jido.Signal.TaskSupervisor
      assert Names.supervisor(jido: MyApp.Jido) == MyApp.Jido.Signal.Supervisor
      assert Names.ext_registry(jido: MyApp.Jido) == MyApp.Jido.Signal.Ext.Registry

      assert Names.bus_runtime_supervisor(jido: MyApp.Jido) ==
               MyApp.Jido.Signal.Bus.RuntimeSupervisor
    end

    test "handles deeply nested instance names" do
      assert Names.registry(jido: MyApp.Multi.Level.Jido) ==
               MyApp.Multi.Level.Jido.Signal.Registry
    end
  end

  describe "Names.instance/1" do
    test "extracts jido instance from options" do
      assert Names.instance([]) == nil
      assert Names.instance(jido: nil) == nil
      assert Names.instance(jido: MyApp.Jido) == MyApp.Jido
    end
  end

  describe "Instance.start_link/1" do
    test "global signal supervisor uses rest_for_one strategy" do
      assert :rest_for_one == Jido.Signal.Supervisor |> :sys.get_state() |> elem(2)
    end

    test "starts instance supervisor with all children" do
      instance = :"TestInstance#{System.unique_integer()}"
      assert {:ok, pid} = Instance.start_link(name: instance)
      assert is_pid(pid)

      instance_opts = [jido: instance]

      # Verify all child processes are running
      assert Process.whereis(Names.supervisor(instance_opts)) == pid
      assert Process.whereis(Names.registry(instance_opts)) |> is_pid()
      assert Process.whereis(Names.task_supervisor(instance_opts)) |> is_pid()
      assert Process.whereis(Names.ext_registry(instance_opts)) |> is_pid()
      assert Process.whereis(Names.bus_runtime_supervisor(instance_opts)) |> is_pid()

      # Cleanup
      Instance.stop(instance)
    end

    test "instance supervisor uses rest_for_one strategy" do
      instance = :"TestInstance#{System.unique_integer()}"
      assert {:ok, pid} = Instance.start_link(name: instance)

      assert :rest_for_one == pid |> :sys.get_state() |> elem(2)

      Instance.stop(instance)
    end

    test "running?/1 returns true for started instance" do
      instance = :"TestInstance#{System.unique_integer()}"
      refute Instance.running?(instance)

      {:ok, _pid} = Instance.start_link(name: instance)
      assert Instance.running?(instance)

      Instance.stop(instance)
      refute Instance.running?(instance)
    end

    test "multiple instances are isolated" do
      instance1 = :"TestInstance1_#{System.unique_integer()}"
      instance2 = :"TestInstance2_#{System.unique_integer()}"

      {:ok, pid1} = Instance.start_link(name: instance1)
      {:ok, pid2} = Instance.start_link(name: instance2)

      # Different supervisors
      assert pid1 != pid2

      # Different registries
      reg1 = Process.whereis(Names.registry(jido: instance1))
      reg2 = Process.whereis(Names.registry(jido: instance2))
      assert reg1 != reg2

      # Cleanup
      Instance.stop(instance1)
      Instance.stop(instance2)
    end
  end

  describe "Instance.stop/1" do
    test "stops instance and all children" do
      instance = :"TestInstance#{System.unique_integer()}"
      {:ok, _pid} = Instance.start_link(name: instance)

      instance_opts = [jido: instance]
      supervisor_pid = Process.whereis(Names.supervisor(instance_opts))
      registry_pid = Process.whereis(Names.registry(instance_opts))

      assert :ok = Instance.stop(instance)

      refute Process.alive?(supervisor_pid)
      refute Process.alive?(registry_pid)
    end

    test "stop/1 is idempotent" do
      instance = :"TestInstance#{System.unique_integer()}"
      assert :ok = Instance.stop(instance)
    end

    test "stop/1 tolerates supervisor disappearing between lookup and stop" do
      instance = :"TestInstance#{System.unique_integer()}"
      {:ok, _pid} = Instance.start_link(name: instance)

      supervisor_name = Names.supervisor(jido: instance)
      supervisor_pid = Process.whereis(supervisor_name)
      mon_ref = Process.monitor(supervisor_pid)
      Process.unlink(supervisor_pid)
      Process.exit(supervisor_pid, :kill)
      assert_receive {:DOWN, ^mon_ref, :process, ^supervisor_pid, _reason}

      assert :ok = Instance.stop(instance)
    end
  end

  describe "instance-scoped task supervisor usage" do
    defmodule PassThroughMiddleware do
      @behaviour Jido.Signal.Bus.Middleware

      @impl true
      def init(opts), do: {:ok, opts}

      @impl true
      def before_publish(signals, _context, state), do: {:cont, signals, state}
    end

    test "dispatch_batch uses instance task supervisor when jido option is provided" do
      instance = :"DispatchScoped#{System.unique_integer([:positive])}"
      {:ok, _pid} = Instance.start_link(name: instance)

      signal =
        Signal.new!(type: "instance.dispatch.batch", source: "/instance", data: %{ok: true})

      task = Task.async(fn -> Dispatch.dispatch_batch(signal, [{:noop, []}], jido: instance) end)

      :ok = :sys.suspend(Jido.Signal.TaskSupervisor)

      try do
        assert {:ok, :ok} = Task.yield(task, 300)
      after
        Task.shutdown(task, :brutal_kill)
        :ok = :sys.resume(Jido.Signal.TaskSupervisor)
        Instance.stop(instance)
      end
    end

    test "middleware timeout runner uses instance task supervisor when bus is scoped" do
      instance = :"MiddlewareScoped#{System.unique_integer([:positive])}"
      {:ok, _pid} = Instance.start_link(name: instance)

      bus_name = :"instance_bus_#{System.unique_integer([:positive])}"

      {:ok, bus_pid} =
        Bus.start_link(
          name: bus_name,
          jido: instance,
          middleware: [{PassThroughMiddleware, []}]
        )

      signal =
        Signal.new!(type: "instance.middleware.publish", source: "/instance", data: %{ok: true})

      task = Task.async(fn -> Bus.publish(bus_pid, [signal]) end)

      :ok = :sys.suspend(Jido.Signal.TaskSupervisor)

      try do
        assert {:ok, {:ok, [_recorded]}} = Task.yield(task, 300)
      after
        Task.shutdown(task, :brutal_kill)
        :ok = :sys.resume(Jido.Signal.TaskSupervisor)
        Instance.stop(instance)
      end
    end
  end
end
