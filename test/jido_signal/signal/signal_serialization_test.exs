defmodule Jido.SignalSerializationTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Serialization.{ErlangTermSerializer, JsonSerializer, MsgpackSerializer}

  test "serializes and deserializes a Signal" do
    signal =
      Signal.new!("test.event", %{"message" => "hello"},
        source: "/test",
        id: "test-id",
        subject: "subject",
        time: "2026-08-26T12:00:00Z",
        datacontenttype: "application/json"
      )

    assert {:ok, json} = Signal.serialize(signal)
    assert Jason.decode!(json)["specversion"] == "1.0"
    assert {:ok, decoded} = Signal.deserialize(json)
    assert Signal.to_map(decoded) == Signal.to_map(signal)
  end

  test "serializes and deserializes a list" do
    signals = [
      Signal.new!(type: "first.event", source: "/test", id: "first"),
      Signal.new!(type: "second.event", source: "/test", id: "second")
    ]

    assert {:ok, json} = Signal.serialize(signals)
    assert {:ok, decoded} = Signal.deserialize(json)
    assert Enum.map(decoded, & &1.id) == ["first", "second"]
  end

  test "normalizes a legacy CloudEvents document patch value" do
    json =
      ~s({"specversion":"1.0.2","id":"legacy","source":"/test","type":"test.event"})

    assert {:ok, signal} = Signal.deserialize(json)
    assert signal.specversion == "1.0"
  end

  test "returns an error for invalid JSON or an invalid envelope" do
    assert {:error, _reason} = Signal.deserialize(~s({"type":"broken"))
    assert {:error, error} = Signal.deserialize(~s({"type":"test.event"}))
    assert error =~ "source"
  end

  test "round-trips flat context attributes in all serializers" do
    signal = Signal.new!(type: "test.event", source: "/test", id: "test-id")
    assert {:ok, signal} = Signal.put_context(signal, "tenantid", "tenant-123")
    assert {:ok, signal} = Signal.put_context(signal, "attempt", 2)

    for serializer <- [JsonSerializer, MsgpackSerializer, ErlangTermSerializer] do
      assert {:ok, binary} = Signal.serialize(signal, serializer: serializer)
      assert {:ok, decoded} = Signal.deserialize(binary, serializer: serializer)
      assert decoded.extensions == %{"tenantid" => "tenant-123", "attempt" => 2}
    end
  end

  test "serialize!/2 returns a binary" do
    signal = Signal.new!(type: "test.event", source: "/test")
    assert is_binary(Signal.serialize!(signal))
  end
end
