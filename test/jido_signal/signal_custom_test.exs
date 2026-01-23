defmodule Jido.Signal.CustomTest do
  use ExUnit.Case, async: true

  alias Jido.Signal.ID

  # Define a test Signal module
  defmodule TestSignal do
    use Jido.Signal,
      type: "test.signal",
      schema: [
        user_id: [type: :string, required: true],
        message: [type: :string, required: true],
        count: [type: :integer, default: 1]
      ]
  end

  # Define another test Signal module with minimal config
  defmodule SimpleSignal do
    use Jido.Signal,
      type: "simple.signal"
  end

  # Define a Signal with additional CloudEvents fields
  defmodule ComplexSignal do
    use Jido.Signal,
      type: "complex.signal",
      default_source: "/test/source",
      datacontenttype: "application/json",
      dataschema: "https://example.com/schema",
      schema: [
        action: [type: :string, required: true],
        priority: [type: {:in, [:low, :medium, :high]}, default: :medium]
      ]
  end

  describe "TestSignal" do
    test "creates valid signal with required data" do
      data = %{user_id: "123", message: "Hello World"}

      assert {:ok, signal} = TestSignal.new(data)
      assert %Jido.Signal{} = signal
      assert signal.type == "test.signal"
      assert signal.data == %{user_id: "123", message: "Hello World", count: 1}
      assert signal.specversion == "1.0.2"
      assert is_binary(signal.id)
      assert is_binary(signal.time)
    end

    test "creates signal with new! function" do
      data = %{user_id: "456", message: "Test"}

      signal = TestSignal.new!(data)
      assert %Jido.Signal{} = signal
      assert signal.type == "test.signal"
      assert signal.data.user_id == "456"
    end

    test "validates required fields" do
      data = %{message: "Missing user_id"}

      assert {:error, error} = TestSignal.new(data)
      assert error =~ "user_id"
      assert error =~ "required"
    end

    test "validates data types" do
      data = %{user_id: "123", message: "Hello", count: "not_an_integer"}

      assert {:error, error} = TestSignal.new(data)
      assert error =~ "expected integer"
    end

    test "uses default values from schema" do
      data = %{user_id: "123", message: "Hello"}

      assert {:ok, signal} = TestSignal.new(data)
      assert signal.data.count == 1
    end

    test "allows overriding signal options" do
      data = %{user_id: "123", message: "Hello"}
      opts = [source: "/custom/source", subject: "custom-subject"]

      assert {:ok, signal} = TestSignal.new(data, opts)
      assert signal.source == "/custom/source"
      assert signal.subject == "custom-subject"
    end

    test "exposes metadata functions" do
      assert TestSignal.type() == "test.signal"
      # Schema is now a Zoi schema struct
      schema = TestSignal.schema()
      assert schema != nil
      assert TestSignal.default_source() == nil

      metadata = TestSignal.to_json()
      assert metadata.type == "test.signal"
      # Schema in metadata is also the Zoi schema
      assert metadata.schema != nil
    end

    test "validates data with validate_data/1" do
      valid_data = %{user_id: "123", message: "Hello"}
      assert {:ok, validated} = TestSignal.validate_data(valid_data)
      assert validated.count == 1

      invalid_data = %{message: "Missing user_id"}
      assert {:error, error} = TestSignal.validate_data(invalid_data)
      assert error =~ "user_id"
      assert error =~ "required"
    end
  end

  describe "SimpleSignal" do
    test "creates signal without schema validation" do
      data = %{anything: "goes", number: 42}

      assert {:ok, signal} = SimpleSignal.new(data)
      assert signal.type == "simple.signal"
      assert signal.data == data
    end

    test "works with empty data" do
      assert {:ok, signal} = SimpleSignal.new()
      assert signal.type == "simple.signal"
      assert signal.data == %{}
    end
  end

  describe "ComplexSignal" do
    test "uses configured CloudEvents fields" do
      data = %{action: "test_action"}

      assert {:ok, signal} = ComplexSignal.new(data)
      assert signal.type == "complex.signal"
      assert signal.source == "/test/source"
      assert signal.datacontenttype == "application/json"
      assert signal.dataschema == "https://example.com/schema"
      assert signal.data.priority == :medium
    end

    test "allows runtime override of source and other fields" do
      data = %{action: "test_action"}

      opts = [
        source: "/runtime/source",
        subject: "runtime-subject"
      ]

      assert {:ok, signal} = ComplexSignal.new(data, opts)
      assert signal.type == "complex.signal"
      assert signal.source == "/runtime/source"
      assert signal.subject == "runtime-subject"
      assert signal.datacontenttype == "application/json"
    end

    test "validates enum fields" do
      valid_data = %{action: "test", priority: :high}
      assert {:ok, signal} = ComplexSignal.new(valid_data)
      assert signal.data.priority == :high

      invalid_data = %{action: "test", priority: :invalid}
      assert {:error, error} = ComplexSignal.new(invalid_data)
      assert error =~ "expected one of"
    end
  end

  describe "Signal ID generation" do
    test "generates valid UUID7 IDs" do
      {:ok, signal} = TestSignal.new(%{user_id: "123", message: "test"})

      assert ID.valid?(signal.id)

      # Extract timestamp should work
      timestamp = ID.extract_timestamp(signal.id)
      assert is_integer(timestamp)
      assert timestamp > 0
    end

    test "IDs are unique across multiple signals" do
      data = %{user_id: "123", message: "test"}

      {:ok, signal1} = TestSignal.new(data)
      {:ok, signal2} = TestSignal.new(data)

      assert signal1.id != signal2.id
    end
  end

  describe "Signal serialization" do
    test "can serialize and deserialize custom signals" do
      data = %{user_id: "123", message: "Hello"}
      {:ok, original} = TestSignal.new(data)

      {:ok, json} = Jido.Signal.serialize(original)
      assert is_binary(json)

      {:ok, deserialized} = Jido.Signal.deserialize(json)
      assert deserialized.type == original.type
      # Data keys become strings after JSON serialization/deserialization
      expected_data = %{"count" => 1, "message" => "Hello", "user_id" => "123"}
      assert deserialized.data == expected_data
      assert deserialized.id == original.id
    end
  end

  describe "error handling" do
    test "new! raises on validation errors" do
      data = %{message: "Missing user_id"}

      assert_raise RuntimeError, fn ->
        TestSignal.new!(data)
      end
    end

    test "provides meaningful error messages" do
      # user_id should be string
      data = %{user_id: 123, message: "Hello"}

      assert {:error, error} = TestSignal.new(data)
      assert error =~ "expected string"
    end
  end
end
