defmodule Jido.Signal.Bus.SupervisionTest do
  use ExUnit.Case, async: false

  alias Jido.Signal.Bus
  alias Jido.Signal.Instance
  alias Jido.Signal.Names

  describe "bus-owned supervisors" do
    test "starts child and partition supervisors under global signal supervisor" do
      bus_name = :"supervision_global_#{System.unique_integer([:positive])}"
      {:ok, bus_pid} = Bus.start_link(name: bus_name, partition_count: 2)

      bus_state = :sys.get_state(bus_pid)
      runtime_supervisor = Jido.Signal.Bus.RuntimeSupervisor
      runtime_supervisor_pid = Process.whereis(runtime_supervisor)
      root_child_pids = supervisor_child_pids(Jido.Signal.Supervisor)
      child_pids = supervisor_child_pids(runtime_supervisor)

      assert runtime_supervisor_pid in root_child_pids
      assert bus_state.child_supervisor in child_pids
      assert bus_state.partition_supervisor in child_pids

      GenServer.stop(bus_pid, :normal)
    end

    test "stopping bus also terminates managed supervisors" do
      bus_name = :"supervision_cleanup_#{System.unique_integer([:positive])}"
      {:ok, bus_pid} = Bus.start_link(name: bus_name, partition_count: 2)

      bus_state = :sys.get_state(bus_pid)
      child_supervisor = bus_state.child_supervisor
      partition_supervisor = bus_state.partition_supervisor

      child_ref = Process.monitor(child_supervisor)
      partition_ref = Process.monitor(partition_supervisor)

      GenServer.stop(bus_pid, :normal)

      assert_receive {:DOWN, ^child_ref, :process, ^child_supervisor, _reason}, 1_000

      assert_receive {:DOWN, ^partition_ref, :process, ^partition_supervisor, _reason},
                     1_000
    end

    test "starts managed supervisors under instance-scoped supervisor" do
      instance = :"SupervisionInstance#{System.unique_integer([:positive])}"
      {:ok, _instance_pid} = Instance.start_link(name: instance)

      bus_name = :"supervision_instance_#{System.unique_integer([:positive])}"
      {:ok, bus_pid} = Bus.start_link(name: bus_name, partition_count: 2, jido: instance)

      bus_state = :sys.get_state(bus_pid)
      runtime_supervisor = Names.bus_runtime_supervisor(jido: instance)
      runtime_supervisor_pid = Process.whereis(runtime_supervisor)
      instance_child_pids = supervisor_child_pids(Names.supervisor(jido: instance))
      child_pids = supervisor_child_pids(runtime_supervisor)

      assert runtime_supervisor_pid in instance_child_pids
      assert bus_state.child_supervisor in child_pids
      assert bus_state.partition_supervisor in child_pids

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
end
