defmodule Jido.Signal.Serialization.FacadeTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Serialization
  alias Jido.Signal.Serialization.ErlangTermSerializer

  test "round-trips a Signal with the default format" do
    signal = Signal.new!("serialization.created", %{"id" => 1}, source: "/test")

    assert {:ok, encoded} = Serialization.serialize(signal)
    assert {:ok, decoded} = Serialization.deserialize(encoded)
    assert Signal.to_map(decoded) == Signal.to_map(signal)
  end

  test "round-trips a Signal with an explicit serializer" do
    signal = Signal.new!("serialization.created", %{"id" => 1}, source: "/test")
    opts = [serializer: ErlangTermSerializer]

    assert {:ok, encoded} = Serialization.serialize(signal, opts)
    assert {:ok, decoded} = Serialization.deserialize(encoded, opts)
    assert Signal.to_map(decoded) == Signal.to_map(signal)
  end
end
