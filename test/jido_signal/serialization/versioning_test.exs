defmodule Jido.Signal.Serialization.VersioningTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Serialization.{ErlangTermSerializer, JsonSerializer, MsgpackSerializer}

  test "canonical output uses CloudEvents 1.0 without a Jido marker" do
    signal = Signal.new!(type: "test.event", source: "/test")

    assert {:ok, json} = JsonSerializer.serialize(signal)
    map = Jason.decode!(json)

    assert map["specversion"] == "1.0"
    refute Map.has_key?(map, "jido_schema_version")
  end

  test "reads supported legacy Jido wire markers" do
    for version <- [1, 2] do
      json =
        Jason.encode!(%{
          "specversion" => "1.0.2",
          "id" => "legacy-#{version}",
          "source" => "/test",
          "type" => "test.event",
          "jido_schema_version" => version
        })

      assert {:ok, signal} = Signal.deserialize(json)
      assert signal.specversion == "1.0"
      assert signal.id == "legacy-#{version}"
    end
  end

  test "rejects an unsupported legacy Jido wire marker" do
    json =
      Jason.encode!(%{
        "specversion" => "1.0",
        "id" => "123",
        "source" => "/test",
        "type" => "test.event",
        "jido_schema_version" => 999
      })

    assert {:error, error} = Signal.deserialize(json)
    assert error =~ "unsupported jido_schema_version 999"
  end

  test "all formats use the same canonical representation" do
    signal =
      Signal.new!("test.crossformat", %{"count" => 2},
        source: "/test",
        id: "cross-format",
        subject: "subject"
      )

    decoded =
      for serializer <- [JsonSerializer, MsgpackSerializer, ErlangTermSerializer] do
        assert {:ok, binary} = Signal.serialize(signal, serializer: serializer)
        assert {:ok, result} = Signal.deserialize(binary, serializer: serializer)
        Signal.to_map(result)
      end

    assert Enum.uniq(decoded) == [Signal.to_map(signal)]
  end
end
