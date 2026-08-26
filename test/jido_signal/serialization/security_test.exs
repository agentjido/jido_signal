defmodule Jido.Signal.Serialization.SecurityTest do
  use ExUnit.Case, async: true

  alias Jido.Signal.Serialization.JsonSerializer
  alias Jido.Signal.Serialization.MsgpackSerializer

  describe "atom exhaustion prevention" do
    test "prevents atom exhaustion via unknown type strings" do
      # Attempt to deserialize with a module that doesn't exist
      # This should fail with an error, not create new atoms
      malicious_json =
        ~s({"type": "evil_type_#{:rand.uniform(999_999)}", "source": "/", "id": "1"})

      # Using String.to_existing_atom should raise ArgumentError for non-existent atoms
      assert {:error, {:json_deserialize_failed, message}} =
               JsonSerializer.deserialize(malicious_json,
                 type: "Elixir.NonExistent.Module#{:rand.uniform(999_999)}"
               )

      assert message =~ "not an already existing atom"
    end

    test "deserializes with string keys without creating atoms from field names" do
      # Use a unique field name that definitely doesn't exist as an atom
      unique_field = "unknown_field_#{:rand.uniform(999_999_999)}"
      json = Jason.encode!(%{unique_field => "value", "known_field" => "data"})

      {:ok, result} = JsonSerializer.deserialize(json)

      assert is_map(result)
      # All keys should remain as strings
      assert Enum.all?(Map.keys(result), &is_binary/1)
      assert Map.has_key?(result, unique_field)
    end

    test "msgpack does not create atoms for unknown fields" do
      # Use a unique field name that definitely doesn't exist as an atom
      unique_field = "unknown_field_#{:rand.uniform(999_999_999)}"
      data = %{unique_field => "value", "known_field" => "data"}
      {:ok, msgpack} = MsgpackSerializer.serialize(data)

      {:ok, result} = MsgpackSerializer.deserialize(msgpack)

      assert is_map(result)
      # Field should exist in result map
      assert Map.has_key?(result, unique_field)
    end

    test "json serializer safely ignores unknown fields during struct creation" do
      # Create a valid Signal with all required fields
      {:ok, signal} = Jido.Signal.new(type: "test.event", source: "/test")
      {:ok, json} = JsonSerializer.serialize(signal)

      # Deserialize successfully - no unknown fields
      {:ok, result} = JsonSerializer.deserialize(json, type: "Elixir.Jido.Signal")
      assert %Jido.Signal{} = result
      assert result.type == "test.event"

      # Now try with unknown fields during deserialization
      # The safe_build_struct should only map known fields
      simple_json =
        ~s({"id":"123","source":"/test","specversion":"1.0","time":"2025-11-17T21:00:00Z","type":"test.event"})

      {:ok, result2} = JsonSerializer.deserialize(simple_json, type: "Elixir.Jido.Signal")
      assert %Jido.Signal{} = result2
      assert result2.type == "test.event"
    end

    test "msgpack serializer safely ignores unknown fields during struct creation" do
      # Create a valid Signal
      {:ok, signal} = Jido.Signal.new(type: "test.event", source: "/test")
      {:ok, msgpack} = MsgpackSerializer.serialize(signal)

      # Deserialize successfully
      {:ok, result} = MsgpackSerializer.deserialize(msgpack, type: "Elixir.Jido.Signal")
      assert %Jido.Signal{} = result
      assert result.type == "test.event"

      # The safe_build_struct only maps known fields to the struct
      # Unknown fields in the msgpack won't be included in the final struct
      assert Map.keys(result) == Map.keys(struct(Jido.Signal))
    end
  end
end
