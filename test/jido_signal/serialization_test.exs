defmodule JidoTest.Signal.SerializationTest do
  use ExUnit.Case

  alias Jido.Signal.Serialization.{JsonDecoder, JsonSerializer, ModuleNameTypeProvider}
  alias JidoTest.TestStructs.{CustomDecodedStruct, TestStruct}

  describe "JsonSerializer" do
    test "serializes and deserializes structs" do
      original = %TestStruct{field1: "test", field2: 123}
      {:ok, serialized} = JsonSerializer.serialize(original)

      {:ok, deserialized} =
        JsonSerializer.deserialize(serialized, type: "Elixir.JidoTest.TestStructs.TestStruct")

      assert deserialized == original
    end

    test "serializes and deserializes structs with nil values" do
      original = %TestStruct{field1: nil, field2: nil}
      {:ok, serialized} = JsonSerializer.serialize(original)

      {:ok, deserialized} =
        JsonSerializer.deserialize(serialized, type: "Elixir.JidoTest.TestStructs.TestStruct")

      assert deserialized == original
    end

    test "serializes and deserializes structs with nested maps" do
      original = %TestStruct{field1: %{nested: "value"}, field2: 123}
      {:ok, serialized} = JsonSerializer.serialize(original)

      {:ok, deserialized} =
        JsonSerializer.deserialize(serialized, type: "Elixir.JidoTest.TestStructs.TestStruct")

      # After deserialization, nested map keys become strings (security: no unsafe atom creation)
      assert deserialized.field1 == %{"nested" => "value"}
      assert deserialized.field2 == 123
    end

    test "serializes and deserializes structs with lists" do
      original = %TestStruct{field1: [1, 2, 3], field2: ["a", "b", "c"]}
      {:ok, serialized} = JsonSerializer.serialize(original)

      {:ok, deserialized} =
        JsonSerializer.deserialize(serialized, type: "Elixir.JidoTest.TestStructs.TestStruct")

      assert deserialized == original
    end

    test "serializes and deserializes maps" do
      original = %{"key" => "value", "nested" => %{"num" => 42}}
      {:ok, serialized} = JsonSerializer.serialize(original)
      {:ok, deserialized} = JsonSerializer.deserialize(serialized)

      assert deserialized == original
    end

    test "serializes and deserializes empty maps" do
      original = %{}
      {:ok, serialized} = JsonSerializer.serialize(original)
      {:ok, deserialized} = JsonSerializer.deserialize(serialized)

      assert deserialized == original
    end

    test "serializes and deserializes maps with lists" do
      original = %{"list" => [1, 2, %{"nested" => "value"}]}
      {:ok, serialized} = JsonSerializer.serialize(original)
      {:ok, deserialized} = JsonSerializer.deserialize(serialized)

      assert deserialized == original
    end

    test "handles custom JsonDecoder implementation" do
      original = %CustomDecodedStruct{value: 5}
      {:ok, serialized} = JsonSerializer.serialize(original)

      {:ok, deserialized} =
        JsonSerializer.deserialize(serialized,
          type: "Elixir.JidoTest.TestStructs.CustomDecodedStruct"
        )

      # Value doubled by custom decoder
      assert deserialized.value == 10
    end

    test "handles custom JsonDecoder with nil value" do
      original = %CustomDecodedStruct{value: nil}
      {:ok, serialized} = JsonSerializer.serialize(original)

      {:ok, deserialized} =
        JsonSerializer.deserialize(serialized,
          type: "Elixir.JidoTest.TestStructs.CustomDecodedStruct"
        )

      assert deserialized.value == nil
    end

    test "returns error on invalid JSON" do
      {:error, _reason} =
        JsonSerializer.deserialize("{invalid_json",
          type: "Elixir.JidoTest.TestStructs.TestStruct"
        )
    end

    test "returns error on non-existent type" do
      {:error, _reason} = JsonSerializer.deserialize("{}", type: "NonExistentModule")
    end
  end

  describe "Signal boundary validation" do
    test "Signal.deserialize returns an error for an empty type" do
      invalid_json =
        ~s({"specversion":"1.0","type":"","source":"/test","id":"123"})

      assert {:error, error} = Jido.Signal.deserialize(invalid_json)
      assert error =~ "type"
    end

    test "Signal.deserialize returns an error for an empty source" do
      invalid_json =
        ~s({"specversion":"1.0","type":"test.event","source":"","id":"123"})

      assert {:error, error} = Jido.Signal.deserialize(invalid_json)
      assert error =~ "source"
    end

    test "deserialize succeeds for valid Signal" do
      valid_json = ~s({"type": "test.event", "source": "/test", "id": "123"})

      assert {:ok, result} = JsonSerializer.deserialize(valid_json)
      assert result["type"] == "test.event"
      assert result["source"] == "/test"
    end

    test "deserialize allows CloudEvents extensions" do
      json_with_ext = ~s({"type": "test", "source": "/s", "id": "x", "custom_field": "value"})

      assert {:ok, result} = JsonSerializer.deserialize(json_with_ext)
      assert result["type"] == "test"
      assert result["custom_field"] == "value"
    end
  end

  describe "ModuleNameTypeProvider" do
    test "converts struct to type string" do
      struct = %TestStruct{}
      type_string = ModuleNameTypeProvider.to_string(struct)

      assert type_string == "Elixir.JidoTest.TestStructs.TestStruct"
    end

    test "converts type string to struct" do
      type_string = "Elixir.JidoTest.TestStructs.TestStruct"
      struct = ModuleNameTypeProvider.to_struct(type_string)

      assert struct == %TestStruct{}
    end

    test "handles nested module names" do
      type_string = ModuleNameTypeProvider.to_string(%CustomDecodedStruct{})
      assert type_string == "Elixir.JidoTest.TestStructs.CustomDecodedStruct"
    end

    test "raises on invalid module name format" do
      assert_raise ArgumentError, fn ->
        ModuleNameTypeProvider.to_struct("InvalidModuleName")
      end
    end

    test "raises on non-existent module" do
      assert_raise ArgumentError, fn ->
        ModuleNameTypeProvider.to_struct("Elixir.NonExistent.Module")
      end
    end
  end

  describe "JsonDecoder" do
    test "default implementation returns data unchanged" do
      data = %{some: "data"}
      assert JsonDecoder.decode(data) == data
    end

    test "custom implementation modifies data" do
      data = %CustomDecodedStruct{value: 5}
      decoded = JsonDecoder.decode(data)

      assert decoded.value == 10
    end

    test "default implementation handles various data types" do
      assert JsonDecoder.decode(nil) == nil
      assert JsonDecoder.decode([1, 2, 3]) == [1, 2, 3]
      assert JsonDecoder.decode("string") == "string"
      assert JsonDecoder.decode(123) == 123
    end
  end
end
