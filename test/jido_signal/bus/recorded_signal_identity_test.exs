defmodule Jido.Signal.Bus.RecordedSignalIdentityTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus

  test "publish exposes explicit log_id with id alias compatibility" do
    bus_name = :"recorded_identity_publish_#{System.unique_integer([:positive])}"
    start_supervised!({Bus, name: bus_name})

    signal = Signal.new!(type: "test.identity.publish", source: "/test", data: %{value: 1})
    assert {:ok, [recorded]} = Bus.publish(bus_name, [signal])

    assert is_binary(recorded.log_id)
    assert recorded.id == recorded.log_id
  end

  test "replay exposes explicit log_id with id alias compatibility" do
    bus_name = :"recorded_identity_replay_#{System.unique_integer([:positive])}"
    start_supervised!({Bus, name: bus_name})

    signal = Signal.new!(type: "test.identity.replay", source: "/test", data: %{value: 1})
    assert {:ok, [_recorded]} = Bus.publish(bus_name, [signal])

    assert {:ok, [replayed]} = Bus.replay(bus_name, "test.identity.replay", 0)

    assert is_binary(replayed.log_id)
    assert replayed.id == replayed.log_id
  end
end
