defmodule JidoTest.Signal.Bus.SupervisionTest do
  use ExUnit.Case, async: true

  alias Jido.Signal.Bus

  @moduletag :capture_log

  test "bus stops when owned child supervisor exits" do
    Process.flag(:trap_exit, true)

    bus_name = :"test-bus-owned-child-exit-#{System.unique_integer([:positive])}"
    {:ok, bus_pid} = Bus.start_link(name: bus_name)
    bus_state = :sys.get_state(bus_pid)
    child_supervisor = bus_state.child_supervisor
    monitor_ref = Process.monitor(bus_pid)

    Process.exit(child_supervisor, :kill)

    assert_receive {:DOWN, ^monitor_ref, :process, ^bus_pid,
                    {:linked_runtime_exit, ^child_supervisor, :killed}},
                   1_000
  end

  test "bus stops when owned partition supervisor exits" do
    Process.flag(:trap_exit, true)

    bus_name = :"test-bus-partition-supervisor-exit-#{System.unique_integer([:positive])}"
    {:ok, bus_pid} = Bus.start_link(name: bus_name, partition_count: 2)
    bus_state = :sys.get_state(bus_pid)
    partition_supervisor = bus_state.partition_supervisor
    assert is_pid(partition_supervisor)
    monitor_ref = Process.monitor(bus_pid)

    Process.exit(partition_supervisor, :kill)

    assert_receive {:DOWN, ^monitor_ref, :process, ^bus_pid,
                    {:linked_runtime_exit, ^partition_supervisor, :killed}},
                   1_000
  end
end
