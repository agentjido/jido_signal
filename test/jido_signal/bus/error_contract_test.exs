defmodule Jido.Signal.Bus.ErrorContractTest do
  use ExUnit.Case, async: false

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias Jido.Signal.Bus.Supervisor, as: BusSupervisor
  alias Jido.Signal.Error

  test "reconnect returns normalized validation error for missing subscription" do
    bus_name = :"bus_error_reconnect_#{System.unique_integer([:positive])}"
    start_supervised!({Bus, name: bus_name})

    assert {:error, %Error.InvalidInputError{} = error} =
             Bus.reconnect(bus_name, "missing-subscription", self())

    assert error.details[:reason] == :subscription_not_found
  end

  test "dlq APIs return normalized execution errors when journal adapter is absent" do
    bus_name = :"bus_error_dlq_#{System.unique_integer([:positive])}"
    start_supervised!({Bus, name: bus_name})

    assert {:error, %Error.ExecutionFailureError{} = entries_error} =
             Bus.dlq_entries(bus_name, "sub-1")

    assert entries_error.details[:reason] == :no_journal_adapter

    assert {:error, %Error.ExecutionFailureError{} = clear_error} =
             Bus.clear_dlq(bus_name, "sub-1")

    assert clear_error.details[:reason] == :no_journal_adapter
  end

  test "ack returns normalized execution error when persistent subscriber is unavailable" do
    bus_name = :"bus_error_ack_#{System.unique_integer([:positive])}"
    start_supervised!({Bus, name: bus_name})

    {:ok, subscription_id} =
      Bus.subscribe(bus_name, "test.error.ack",
        persistent?: true,
        dispatch: {:pid, target: self(), delivery_mode: :async}
      )

    signal = Signal.new!(type: "test.error.ack", source: "/test", data: %{value: 1})
    {:ok, [recorded]} = Bus.publish(bus_name, [signal])
    assert_receive {:signal, %Signal{type: "test.error.ack"}}, 1_000

    {:ok, bus_pid} = Bus.whereis(bus_name)
    bus_state = :sys.get_state(bus_pid)
    %{persistence_pid: persistence_pid} = Map.fetch!(bus_state.subscriptions, subscription_id)

    GenServer.stop(persistence_pid, :kill)

    assert {:error, %Error.ExecutionFailureError{} = error} =
             Bus.ack(bus_name, subscription_id, recorded.id)

    assert error.details[:reason] == :subscription_not_available
  end

  test "bus_call boundaries return normalized errors when bus is unavailable" do
    missing_bus = :"missing_bus_#{System.unique_integer([:positive])}"
    signal = Signal.new!(type: "test.error.missing_bus", source: "/test", data: %{value: 1})

    assert {:error, %Error.ExecutionFailureError{} = publish_error} =
             Bus.publish(missing_bus, [signal])

    assert publish_error.details[:reason] == :not_found

    assert {:error, %Error.ExecutionFailureError{} = snapshot_error} =
             Bus.snapshot_list(missing_bus)

    assert snapshot_error.details[:reason] == :not_found
  end

  test "snapshot boundaries return normalized structured errors" do
    bus_name = :"bus_error_snapshot_#{System.unique_integer([:positive])}"
    start_supervised!({Bus, name: bus_name})

    assert {:error, %Error.InvalidInputError{} = read_error} =
             Bus.snapshot_read(bus_name, "missing-snapshot")

    assert read_error.details[:reason] == :snapshot_not_found
    assert read_error.details[:field] == :snapshot_id

    assert {:error, %Error.InvalidInputError{} = delete_error} =
             Bus.snapshot_delete(bus_name, "missing-snapshot")

    assert delete_error.details[:reason] == :snapshot_not_found
    assert delete_error.details[:field] == :snapshot_id
  end

  test "public bus boundary rejects non-bus pid targets with normalized error" do
    bus_name = :"bus_error_invalid_target_#{System.unique_integer([:positive])}"
    start_supervised!({Bus, name: bus_name})
    {:ok, bus_supervisor_pid} = BusSupervisor.whereis(bus_name)

    assert {:error, %Error.ExecutionFailureError{} = error} =
             Bus.snapshot_list(bus_supervisor_pid)

    assert error.details[:reason] == :invalid_bus_target
    assert error.details[:action] == :snapshot_list
  end
end
