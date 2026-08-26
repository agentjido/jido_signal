defmodule Jido.Signal.InstanceTest do
  use ExUnit.Case, async: true

  alias Jido.Signal.Instance
  alias Jido.Signal.Names

  describe "internal name resolution" do
    test "returns default when no jido option" do
      assert Names.registry([]) == Jido.Signal.Registry
      assert Names.task_supervisor([]) == Jido.Signal.TaskSupervisor
      assert Names.supervisor([]) == Jido.Signal.Supervisor
    end

    test "returns default when jido is nil" do
      assert Names.registry(jido: nil) == Jido.Signal.Registry
      assert Names.task_supervisor(jido: nil) == Jido.Signal.TaskSupervisor
    end

    test "scopes names when jido instance provided" do
      assert Names.registry(jido: MyApp.Jido) == MyApp.Jido.Signal.Registry
      assert Names.task_supervisor(jido: MyApp.Jido) == MyApp.Jido.Signal.TaskSupervisor
      assert Names.supervisor(jido: MyApp.Jido) == MyApp.Jido.Signal.Supervisor
    end

    test "handles deeply nested instance names" do
      assert Names.registry(jido: MyApp.Multi.Level.Jido) ==
               MyApp.Multi.Level.Jido.Signal.Registry
    end
  end

  describe "Instance.start_link/1" do
    test "starts instance supervisor with all children" do
      instance = __MODULE__.Started
      assert {:ok, pid} = Instance.start_link(name: instance)
      assert is_pid(pid)

      instance_opts = [jido: instance]

      # Verify all child processes are running
      assert Process.whereis(Names.supervisor(instance_opts)) == pid
      assert Process.whereis(Names.registry(instance_opts)) |> is_pid()
      assert Process.whereis(Names.task_supervisor(instance_opts)) |> is_pid()

      # Cleanup
      Instance.stop(instance)
    end

    test "running?/1 returns true for started instance" do
      instance = __MODULE__.Running
      refute Instance.running?(instance)

      {:ok, _pid} = Instance.start_link(name: instance)
      assert Instance.running?(instance)

      Instance.stop(instance)
      refute Instance.running?(instance)
    end

    test "multiple instances are isolated" do
      instance1 = __MODULE__.First
      instance2 = __MODULE__.Second

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

    test "rejects invalid options" do
      assert {:error, {:invalid_options, message}} = Instance.start_link([])
      assert is_binary(message)

      assert {:error, {:invalid_options, message}} =
               Instance.start_link(name: nil, unknown: true)

      assert is_binary(message)

      assert_raise ArgumentError, fn ->
        Instance.child_spec(name: __MODULE__.Invalid, shutdown: -1)
      end
    end
  end

  describe "Instance.stop/1" do
    test "stops instance and all children" do
      instance = __MODULE__.Stopped
      {:ok, _pid} = Instance.start_link(name: instance)

      instance_opts = [jido: instance]
      supervisor_pid = Process.whereis(Names.supervisor(instance_opts))
      registry_pid = Process.whereis(Names.registry(instance_opts))

      assert :ok = Instance.stop(instance)

      refute Process.alive?(supervisor_pid)
      refute Process.alive?(registry_pid)
    end

    test "stop/1 is idempotent" do
      instance = __MODULE__.NotStarted
      assert :ok = Instance.stop(instance)
    end

    test "stop/1 tolerates supervisor exiting between lookup and stop" do
      Process.flag(:trap_exit, true)

      instance = __MODULE__.Race
      {:ok, _pid} = Instance.start_link(name: instance)

      supervisor_pid = Process.whereis(Names.supervisor(jido: instance))
      assert is_pid(supervisor_pid)

      stop_task = Task.async(fn -> Instance.stop(instance) end)
      Process.exit(supervisor_pid, :kill)

      assert :ok = Task.await(stop_task, 1_000)
    end
  end
end
