defmodule Jido.Signal.SerializationTest do
  use ExUnit.Case, async: false

  alias Jido.Signal
  alias Jido.Signal.Serialization

  describe "JSON" do
    test "round-trips one Signal through the canonical map" do
      signal =
        Signal.new!("test.created", %{"count" => 2},
          source: "/test",
          id: "json-1",
          subject: "record/1"
        )

      assert {:ok, json} = Signal.serialize(signal)
      assert Jason.decode!(json) == Signal.to_map(signal)
      assert {:ok, decoded} = Signal.deserialize(json)
      assert decoded == signal
    end

    test "round-trips a list of Signals" do
      signals = [
        Signal.new!(type: "first.created", source: "/test", id: "first"),
        Signal.new!(type: "second.created", source: "/test", id: "second")
      ]

      assert {:ok, json} = Signal.serialize(signals)
      assert {:ok, decoded} = Signal.deserialize(json)
      assert decoded == signals
    end

    test "returns a tagged error for invalid JSON" do
      assert {:error, {:json_decode_failed, message}} = Signal.deserialize("{invalid")
      assert is_binary(message)
    end
  end

  describe "Erlang term format" do
    test "round-trips through the same canonical map" do
      signal = Signal.new!("test.created", %{"count" => 2}, source: "/test")

      assert {:ok, binary} = Signal.serialize(signal, format: :erlang_term)
      assert :erlang.binary_to_term(binary, [:safe]) == Signal.to_map(signal)
      assert {:ok, decoded} = Signal.deserialize(binary, format: :erlang_term)
      assert decoded == signal
    end

    test "returns a tagged error for invalid Erlang term data" do
      assert {:error, {:erlang_term_decode_failed, message}} =
               Signal.deserialize(<<1, 2, 3>>, format: :erlang_term)

      assert is_binary(message)
    end
  end

  describe "Erlang-only Signal data" do
    test "uses an Erlang term binary in data_base64" do
      data = %{status: :ready, value: {1, 2}, bytes: <<0, 255>>}
      signal = Signal.new!("test.binary", data, source: "/test")

      wire = Signal.to_map(signal)
      refute Map.has_key?(wire, "data")
      assert is_binary(wire["data_base64"])

      assert wire["data_base64"]
             |> Base.decode64!()
             |> :erlang.binary_to_term([:safe]) == data

      assert {:ok, decoded} = Signal.from_map(wire)
      assert decoded.data == data
    end

    test "keeps JSON-safe values in data" do
      data = %{"message" => "hello", "items" => [1, true, nil]}
      signal = Signal.new!("test.json", data, source: "/test")

      assert Signal.to_map(signal)["data"] == data
      refute Map.has_key?(Signal.to_map(signal), "data_base64")
    end

    test "rejects invalid or ambiguous data_base64" do
      wire = %{
        "specversion" => "1.0",
        "id" => "binary-1",
        "source" => "/test",
        "type" => "test.binary"
      }

      assert {:error, error} = Signal.from_map(Map.put(wire, "data_base64", "not-base64"))
      assert error =~ "valid Base64"

      encoded = :ok |> :erlang.term_to_binary() |> Base.encode64()

      assert {:error, error} =
               Signal.from_map(Map.merge(wire, %{"data" => "value", "data_base64" => encoded}))

      assert error =~ "mutually exclusive"
    end
  end

  describe "boundary and options" do
    test "validates the decoded Signal envelope" do
      json = ~s({"specversion":"1.0","id":"1","source":"","type":"test.created"})

      assert {:error, error} = Signal.deserialize(json)
      assert error =~ "source"
    end

    test "rejects non-Signal input and unsupported formats" do
      assert {:error, {:invalid_signal, _message}} = Serialization.serialize(%{"type" => "test"})
      assert {:error, {:invalid_signal, _message}} = Serialization.serialize([:not_a_signal])
      assert {:error, {:unsupported_format, :msgpack}} = Signal.serialize([], format: :msgpack)
    end

    test "enforces the payload size for encode and decode" do
      signal = Signal.new!(type: "test.created", source: "/test")
      assert {:ok, json} = Signal.serialize(signal)

      assert {:error, {:payload_too_large, encode_size, 10}} =
               Signal.serialize(signal, max_payload_bytes: 10)

      assert {:error, {:payload_too_large, size, 10}} =
               Signal.deserialize(json, max_payload_bytes: 10)

      assert encode_size == byte_size(json)
      assert size == byte_size(json)
    end

    test "reads the application payload limit" do
      signal = Signal.new!(type: "test.created", source: "/test")
      assert {:ok, json} = Signal.serialize(signal)

      previous = Application.get_env(:jido_signal, :max_payload_bytes)
      Application.put_env(:jido_signal, :max_payload_bytes, 10)

      on_exit(fn ->
        if previous do
          Application.put_env(:jido_signal, :max_payload_bytes, previous)
        else
          Application.delete_env(:jido_signal, :max_payload_bytes)
        end
      end)

      assert {:error, {:payload_too_large, _size, 10}} = Signal.serialize(signal)
      assert {:error, {:payload_too_large, _size, 10}} = Signal.deserialize(json)
    end

    test "serialize!/2 returns a binary" do
      signal = Signal.new!(type: "test.created", source: "/test")
      assert is_binary(Signal.serialize!(signal))
    end
  end

  describe "legacy input" do
    test "normalizes supported v2 wire values" do
      json =
        Jason.encode!(%{
          "specversion" => "1.0.2",
          "jido_schema_version" => 1,
          "id" => "legacy-1",
          "source" => "/test",
          "type" => "test.created"
        })

      assert {:ok, signal} = Signal.deserialize(json)
      assert signal.specversion == "1.0"
      refute Map.has_key?(Signal.to_map(signal), "jido_schema_version")
    end

    test "rejects unsupported v2 wire markers" do
      json =
        Jason.encode!(%{
          "specversion" => "1.0",
          "jido_schema_version" => 999,
          "id" => "legacy-999",
          "source" => "/test",
          "type" => "test.created"
        })

      assert {:error, error} = Signal.deserialize(json)
      assert error =~ "unsupported jido_schema_version 999"
    end
  end
end
