defmodule Jido.Signal.Bus.SupervisionTest do
  use ExUnit.Case, async: false

  alias Jido.Signal.Bus
  alias Jido.Signal.Bus.Supervisor, as: BusSupervisor
  alias Jido.Signal.Instance
  alias Jido.Signal.Names

  describe "per-bus supervision tree" do
    test "starts per-bus subtree under global runtime supervisor" do
      bus_name = :"supervision_global_#{System.unique_integer([:positive])}"
      {:ok, bus_pid} = Bus.start_link(name: bus_name, partition_count: 2)

      bus_state = :sys.get_state(bus_pid)
      {:ok, bus_supervisor_pid} = BusSupervisor.whereis(bus_name)
      runtime_supervisor = Jido.Signal.Bus.RuntimeSupervisor
      runtime_supervisor_pid = Process.whereis(runtime_supervisor)
      root_child_pids = supervisor_child_pids(Jido.Signal.Supervisor)
      runtime_child_pids = supervisor_child_pids(runtime_supervisor)
      bus_child_pids = supervisor_child_pids(bus_supervisor_pid)

      assert runtime_supervisor_pid in root_child_pids
      assert bus_supervisor_pid in runtime_child_pids
      assert bus_pid in bus_child_pids
      assert bus_state.child_supervisor in bus_child_pids
      assert bus_state.partition_supervisor in bus_child_pids

      assert :ok = Bus.stop(bus_pid)
    end

    test "restarts bus worker when bus process crashes" do
      bus_name = :"supervision_bus_restart_#{System.unique_integer([:positive])}"
      {:ok, bus_pid} = Bus.start_link(name: bus_name, partition_count: 2)

      bus_state = :sys.get_state(bus_pid)
      child_supervisor = bus_state.child_supervisor
      partition_supervisor = bus_state.partition_supervisor
      bus_ref = Process.monitor(bus_pid)

      Process.unlink(bus_pid)
      Process.exit(bus_pid, :kill)

      assert_receive {:DOWN, ^bus_ref, :process, ^bus_pid, :killed}, 1_000

      {:ok, restarted_bus_pid} = await_bus_restart(bus_name, bus_pid)
      refute restarted_bus_pid == bus_pid
      assert Process.alive?(child_supervisor)
      assert Process.alive?(partition_supervisor)

      GenServer.stop(restarted_bus_pid, :normal)
    end

    test "restarts partition supervisor and bus when partition supervisor crashes" do
      bus_name = :"supervision_partition_restart_#{System.unique_integer([:positive])}"
      {:ok, bus_pid} = Bus.start_link(name: bus_name, partition_count: 2)

      bus_state = :sys.get_state(bus_pid)
      child_supervisor = bus_state.child_supervisor
      partition_supervisor = bus_state.partition_supervisor
      bus_ref = Process.monitor(bus_pid)
      partition_ref = Process.monitor(partition_supervisor)

      Process.exit(partition_supervisor, :kill)

      assert_receive {:DOWN, ^partition_ref, :process, ^partition_supervisor, :killed}, 1_000
      assert_receive {:DOWN, ^bus_ref, :process, ^bus_pid, _reason}, 1_000

      {:ok, restarted_bus_pid} = await_bus_restart(bus_name, bus_pid)
      restarted_state = :sys.get_state(restarted_bus_pid)

      refute restarted_state.partition_supervisor == partition_supervisor
      assert restarted_state.child_supervisor == child_supervisor

      GenServer.stop(restarted_bus_pid, :normal)
    end

    test "restarts child, partition, and bus when child supervisor crashes" do
      bus_name = :"supervision_child_restart_#{System.unique_integer([:positive])}"
      {:ok, bus_pid} = Bus.start_link(name: bus_name, partition_count: 2)

      bus_state = :sys.get_state(bus_pid)
      child_supervisor = bus_state.child_supervisor
      partition_supervisor = bus_state.partition_supervisor
      bus_ref = Process.monitor(bus_pid)
      child_ref = Process.monitor(child_supervisor)
      partition_ref = Process.monitor(partition_supervisor)

      Process.exit(child_supervisor, :kill)

      assert_receive {:DOWN, ^child_ref, :process, ^child_supervisor, :killed}, 1_000
      assert_receive {:DOWN, ^partition_ref, :process, ^partition_supervisor, _reason}, 1_000
      assert_receive {:DOWN, ^bus_ref, :process, ^bus_pid, _reason}, 1_000

      {:ok, restarted_bus_pid} = await_bus_restart(bus_name, bus_pid)
      restarted_state = :sys.get_state(restarted_bus_pid)

      refute restarted_state.child_supervisor == child_supervisor
      refute restarted_state.partition_supervisor == partition_supervisor

      GenServer.stop(restarted_bus_pid, :normal)
    end

    test "stopping bus also terminates managed supervisors" do
      bus_name = :"supervision_cleanup_#{System.unique_integer([:positive])}"
      {:ok, bus_pid} = Bus.start_link(name: bus_name, partition_count: 2)

      bus_state = :sys.get_state(bus_pid)
      child_supervisor = bus_state.child_supervisor
      partition_supervisor = bus_state.partition_supervisor

      child_ref = Process.monitor(child_supervisor)
      partition_ref = Process.monitor(partition_supervisor)

      assert :ok = Bus.stop(bus_pid)

      await_process_down(child_supervisor, child_ref)
      await_process_down(partition_supervisor, partition_ref)
    end

    test "starts managed supervisors under instance-scoped supervisor" do
      instance = :"SupervisionInstance#{System.unique_integer([:positive])}"
      {:ok, _instance_pid} = Instance.start_link(name: instance)

      bus_name = :"supervision_instance_#{System.unique_integer([:positive])}"
      {:ok, bus_pid} = Bus.start_link(name: bus_name, partition_count: 2, jido: instance)

      bus_state = :sys.get_state(bus_pid)
      {:ok, bus_supervisor_pid} = BusSupervisor.whereis(bus_name, jido: instance)
      runtime_supervisor = Names.bus_runtime_supervisor(jido: instance)
      runtime_supervisor_pid = Process.whereis(runtime_supervisor)
      instance_child_pids = supervisor_child_pids(Names.supervisor(jido: instance))
      runtime_child_pids = supervisor_child_pids(runtime_supervisor)
      bus_child_pids = supervisor_child_pids(bus_supervisor_pid)

      assert runtime_supervisor_pid in instance_child_pids
      assert bus_supervisor_pid in runtime_child_pids
      assert bus_pid in bus_child_pids
      assert bus_state.child_supervisor in bus_child_pids
      assert bus_state.partition_supervisor in bus_child_pids

      GenServer.stop(bus_pid, :normal)
      assert :ok = Instance.stop(instance)
    end
  end

  defp supervisor_child_pids(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
    |> Enum.reject(&is_nil/1)
  end

  defp await_bus_restart(bus_name, stale_pid, attempts \\ 100)

  defp await_bus_restart(_bus_name, _stale_pid, 0), do: {:error, :restart_timeout}

  defp await_bus_restart(bus_name, stale_pid, attempts) do
    case Bus.whereis(bus_name) do
      {:ok, pid} when pid != stale_pid ->
        {:ok, pid}

      _ ->
        receive do
        after
          20 ->
            await_bus_restart(bus_name, stale_pid, attempts - 1)
        end
    end
  end

  defp await_process_down(pid, monitor_ref, timeout_ms \\ 1_000) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        :ok
    after
      timeout_ms ->
        refute Process.alive?(pid)
        :ok
    end
  end
end
