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

  defmodule RequiredPolicyExtension do
    use Jido.Signal.Ext,
      namespace: "requiredext",
      schema: [
        id: [type: :string, required: true]
      ]
  end

  defmodule OptionalPolicyExtension do
    use Jido.Signal.Ext,
      namespace: "optionalext",
      schema: [
        id: [type: :string, required: true]
      ]
  end

  defmodule ForbiddenPolicyExtension do
    use Jido.Signal.Ext,
      namespace: "forbiddenext",
      schema: [
        id: [type: :string, required: true]
      ]
  end

  defmodule PolicySignal do
    use Jido.Signal,
      type: "policy.signal",
      schema: [
        message: [type: :string, required: true]
      ],
      extension_policy: [
        {RequiredPolicyExtension, :required},
        {OptionalPolicyExtension, :optional},
        {ForbiddenPolicyExtension, :forbidden}
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
      assert TestSignal.extension_policy() == %{}

      metadata = TestSignal.to_json()
      assert metadata.type == "test.signal"
      # Schema in metadata is also the Zoi schema
      assert metadata.schema != nil
      assert metadata.extension_policy == %{}
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

  describe "PolicySignal" do
    test "exposes normalized extension policy metadata" do
      expected_policy = %{
        "forbiddenext" => :forbidden,
        "optionalext" => :optional,
        "requiredext" => :required
      }

      assert PolicySignal.extension_policy() == expected_policy
      assert PolicySignal.to_json().extension_policy == expected_policy
      assert PolicySignal.__signal_metadata__().extension_policy == expected_policy
    end

    test "creates a signal when required extension is present via top-level namespace" do
      assert {:ok, signal} =
               PolicySignal.new(%{message: "hello"},
                 requiredext: %{id: "required-123"}
               )

      assert signal.extensions["requiredext"] == %{id: "required-123"}
    end

    test "returns error when required extension is missing" do
      assert {:error, error} = PolicySignal.new(%{message: "hello"})
      assert error =~ "Signal #{inspect(PolicySignal)}"
      assert error =~ "\"requiredext\""
      assert error =~ "requires extension namespace"
    end

    test "returns error when forbidden extension is passed as top-level namespace" do
      assert {:error, error} =
               PolicySignal.new(%{message: "hello"},
                 requiredext: %{id: "required-123"},
                 forbiddenext: %{id: "forbidden-123"}
               )

      assert error =~ "Signal #{inspect(PolicySignal)}"
      assert error =~ "\"forbiddenext\""
      assert error =~ "forbids extension namespace"
    end

    test "returns error when forbidden extension is passed via extensions map" do
      assert {:error, error} =
               PolicySignal.new(%{message: "hello"},
                 requiredext: %{id: "required-123"},
                 extensions: %{"forbiddenext" => %{id: "forbidden-123"}}
               )

      assert error =~ "Signal #{inspect(PolicySignal)}"
      assert error =~ "\"forbiddenext\""
      assert error =~ "forbids extension namespace"
    end

    test "allows optional extension to be omitted" do
      assert {:ok, signal} =
               PolicySignal.new(%{message: "hello"},
                 requiredext: %{id: "required-123"}
               )

      assert signal.extensions["requiredext"] == %{id: "required-123"}
      refute Map.has_key?(signal.extensions, "optionalext")
    end

    test "prefers explicit extensions map over top-level namespace input" do
      assert {:ok, signal} =
               PolicySignal.new(%{message: "hello"},
                 requiredext: %{id: "top-level"},
                 extensions: %{"requiredext" => %{id: "explicit"}}
               )

      assert signal.extensions["requiredext"] == %{id: "explicit"}
    end

    test "returns error when effective required extension data is invalid" do
      assert {:error, error} =
               PolicySignal.new(%{message: "hello"},
                 requiredext: %{}
               )

      assert error =~ "Signal #{inspect(PolicySignal)}"
      assert error =~ "\"requiredext\""
      assert error =~ "invalid data for extension namespace"
      assert error =~ "required :id option not found"
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

    test "rejects invalid extension policy modes at compile time" do
      assert_raise CompileError, ~r/extension_policy.*must be one of/, fn ->
        defmodule InvalidPolicyModeSignal do
          use Jido.Signal,
            type: "invalid.policy.mode.signal",
            extension_policy: [
              {RequiredPolicyExtension, :sometimes}
            ]
        end
      end
    end

    test "rejects non-module extension policy keys at compile time" do
      assert_raise CompileError, ~r/extension_policy keys must be compiled modules/, fn ->
        defmodule InvalidPolicyModuleSignal do
          use Jido.Signal,
            type: "invalid.policy.module.signal",
            extension_policy: [
              {:not_a_module, :required}
            ]
        end
      end
    end

    test "rejects duplicate extension policy namespaces at compile time" do
      defmodule DuplicatePolicyExtensionOne do
        use Jido.Signal.Ext,
          namespace: "duplicatepolicy"
      end

      defmodule DuplicatePolicyExtensionTwo do
        use Jido.Signal.Ext,
          namespace: "duplicatepolicy"
      end

      assert_raise CompileError,
                   ~r/extension_policy declares namespace "duplicatepolicy" more than once/,
                   fn ->
                     defmodule DuplicatePolicySignal do
                       use Jido.Signal,
                         type: "duplicate.policy.signal",
                         extension_policy: [
                           {DuplicatePolicyExtensionOne, :required},
                           {DuplicatePolicyExtensionTwo, :optional}
                         ]
                     end
                   end
    end
  end
end
