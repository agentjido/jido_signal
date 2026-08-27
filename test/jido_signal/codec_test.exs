defmodule Jido.Signal.CodecTest do
  use ExUnit.Case, async: true

  alias Jido.Signal

  test "parses and emits a complete CloudEvents envelope" do
    map = %{
      "specversion" => "1.0",
      "id" => "123",
      "source" => "/example",
      "type" => "example.event",
      "subject" => "record/123",
      "time" => "2026-08-26T12:00:00Z",
      "datacontenttype" => "application/json",
      "dataschema" => "https://example.com/schema",
      "data" => %{"value" => 1}
    }

    assert {:ok, signal} = Signal.from_map(map)
    assert signal.id == "123"
    assert signal.specversion == "1.0"
    assert signal.data == %{"value" => 1}
    assert Signal.to_map(signal) == map
  end

  test "does not generate missing required wire attributes" do
    assert {:error, error} =
             Signal.from_map(%{"specversion" => "1.0", "source" => "/example"})

    assert error =~ "id"
    assert error =~ "type"
  end

  test "normalizes the supported legacy spec version" do
    assert {:ok, signal} =
             Signal.from_map(%{
               "specversion" => "1.0.2",
               "id" => "123",
               "source" => "/example",
               "type" => "example.event"
             })

    assert signal.specversion == "1.0"
    assert Signal.to_map(signal)["specversion"] == "1.0"
  end

  test "rejects unsupported spec versions" do
    assert {:error, error} =
             Signal.from_map(%{
               "specversion" => "0.3",
               "id" => "123",
               "source" => "/example",
               "type" => "example.event"
             })

    assert error =~ "specversion"
  end

  test "rejects invalid map and encoded data boundaries" do
    assert {:error, "parse error: expected a map"} = Signal.from_map(:not_a_map)

    wire = %{
      "specversion" => "1.0",
      "id" => "encoded-1",
      "source" => "/example",
      "type" => "example.encoded"
    }

    assert {:error, error} = Signal.from_map(Map.put(wire, "data_base64", 123))
    assert error =~ "Base64 string"

    unsafe_binary = Base.encode64(<<131, 255>>)
    assert {:error, error} = Signal.from_map(Map.put(wire, "data_base64", unsafe_binary))
    assert error =~ "safe Erlang term"
  end

  test "accepts supported legacy wire markers" do
    for marker <- [nil, 1, 2] do
      assert {:ok, signal} =
               Signal.from_map(%{
                 "specversion" => "1.0",
                 "jido_schema_version" => marker,
                 "id" => "legacy-#{inspect(marker)}",
                 "source" => "/example",
                 "type" => "example.legacy"
               })

      refute Map.has_key?(Signal.to_map(signal), "jido_schema_version")
    end
  end
end
