defmodule Jido.Signal.CustomTest do
  use ExUnit.Case, async: true

  alias Jido.Signal.CustomTest, as: CustomTest
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

  defmodule ZoiSignal do
    use Jido.Signal,
      type: "zoi.signal",
      schema:
        Zoi.object(%{
          user_id: Zoi.string(),
          email:
            Zoi.string()
            |> Zoi.refine(fn email ->
              if String.contains?(email, "@"), do: :ok, else: {:error, "must contain @"}
            end),
          count: Zoi.integer() |> Zoi.default(1)
        })
  end

  defmodule VariableZoiSignal do
    field_schema = Zoi.string()

    use Jido.Signal,
      type: "variable.zoi.signal",
      schema: Zoi.object(%{value: field_schema})
  end

  defmodule ScopedClosureSignal do
    value = :outer
    item = :outer
    quoted_value = :outer

    use Jido.Signal,
      type: "scoped.closure.signal",
      schema:
        Zoi.object(%{
          value:
            Zoi.integer()
            |> Zoi.refine(fn value ->
              _quoted = quote(do: quoted_value)

              if match?({:ok, item} when item > 0, {:ok, value}),
                do: :ok,
                else: {:error, "must be positive"}
            end)
        })

    @outer_values {value, item, quoted_value}
    def outer_values, do: @outer_values
  end

  defmodule ScalarTransformSignal do
    use Jido.Signal,
      type: "scalar.transform.signal",
      schema: Zoi.object(%{}) |> Zoi.transform(fn _data -> :invalid end)
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
      schema = TestSignal.schema()
      assert is_list(schema)
      assert TestSignal.default_source() == nil
      assert TestSignal.extension_policy() == %{}

      metadata = TestSignal.to_json()
      assert metadata.type == "test.signal"
      assert is_list(metadata.schema)
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

  describe "ZoiSignal" do
    test "creates a Signal with valid data and applies defaults" do
      assert {:ok, signal} =
               ZoiSignal.new(%{user_id: "123", email: "user@example.com"})

      assert signal.type == "zoi.signal"
      assert signal.data == %{user_id: "123", email: "user@example.com", count: 1}
      assert %Zoi.Types.Map{} = ZoiSignal.schema()
      assert %Zoi.Types.Map{} = ZoiSignal.to_json().schema
    end

    test "returns a useful error for invalid data" do
      assert {:error, error} = ZoiSignal.new(%{user_id: "123", email: "invalid"})

      assert is_binary(error)
      assert error =~ "Invalid parameters for Signal"
      assert error =~ "email"
      assert error =~ "must contain @"
    end

    test "preserves an inline refinement function" do
      assert {:ok, validated} =
               ZoiSignal.validate_data(%{user_id: "123", email: "user@example.com"})

      assert validated.count == 1

      assert {:error, error} =
               ZoiSignal.validate_data(%{user_id: "123", email: "invalid"})

      assert error =~ "must contain @"
    end

    test "uses the direct Zoi unknown-key behavior" do
      assert {:ok, signal} =
               ZoiSignal.new(%{
                 user_id: "123",
                 email: "user@example.com",
                 extra: "removed"
               })

      refute Map.has_key?(signal.data, :extra)
    end
  end

  describe "Zoi schema loading" do
    test "stores a schema that contains a caller variable" do
      assert {:ok, signal} = VariableZoiSignal.new(%{value: "stored"})
      assert signal.data == %{value: "stored"}
      assert %Zoi.Types.Map{} = VariableZoiSignal.schema()
    end

    test "keeps inline closure scope separate from caller variables" do
      assert ScopedClosureSignal.outer_values() == {:outer, :outer, :outer}
      assert {:ok, %{value: 1}} = ScopedClosureSignal.validate_data(%{value: 1})

      assert {:error, error} = ScopedClosureSignal.validate_data(%{value: 0})
      assert error =~ "must be positive"
    end

    test "evaluates non-literal options once" do
      module = unique_module("CountedOptionsSignal")
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      create_module(
        module,
        quote do
          use Jido.Signal, CustomTest.counted_options(unquote(counter))
        end
      )

      assert Agent.get(counter, & &1) == 1
      assert module.type() == "counted.options.signal"
    end

    test "builds a storable schema once" do
      module = unique_module("CountedSchemaSignal")
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      create_module(
        module,
        quote do
          counter = unquote(counter)

          use Jido.Signal,
            type: "counted.schema.signal",
            schema: CustomTest.counted_schema(counter)
        end
      )

      assert Agent.get(counter, & &1) == 1
      assert %Zoi.Types.Map{} = module.schema()
      assert %Zoi.Types.Map{} = module.schema()
      assert {:ok, %{value: 1}} = module.validate_data(%{value: 1})
      assert Agent.get(counter, & &1) == 1
    end

    test "reports a closure schema from dynamic options" do
      module = unique_module("DynamicClosureSignal")

      assert_raise CompileError,
                   ~r/closure-based :schema must be declared inline without caller variables/,
                   fn ->
                     create_module(
                       module,
                       quote do
                         opts = [
                           type: "dynamic.closure.signal",
                           schema:
                             Zoi.object(%{
                               value:
                                 Zoi.integer()
                                 |> Zoi.refine(fn value -> value > 0 end)
                             })
                         ]

                         use Jido.Signal, opts
                       end
                     )
                   end
    end

    test "rejects a Zoi schema that cannot accept map data" do
      module = unique_module("ScalarSchemaSignal")

      assert_raise CompileError, ~r/must accept map-shaped Signal data/, fn ->
        create_module(
          module,
          quote do
            use Jido.Signal,
              type: "scalar.schema.signal",
              schema: Zoi.integer()
          end
        )
      end
    end

    test "rejects a non-map result from a Zoi transform" do
      assert {:error, error} = ScalarTransformSignal.validate_data(%{})
      assert error =~ "Zoi schema validation must return a map"
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

    test "keeps no-schema payloads unchanged" do
      assert {:ok, "anything"} = SimpleSignal.validate_data("anything")
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

    test "prefers explicit extensions map with atom keys over top-level namespace input" do
      assert {:ok, signal} =
               PolicySignal.new(%{message: "hello"},
                 requiredext: %{id: "top-level"},
                 extensions: %{requiredext: %{id: "explicit"}}
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

    test "returns error when explicit extensions map contains invalid required data" do
      assert {:error, error} =
               PolicySignal.new(%{message: "hello"},
                 extensions: %{requiredext: %{}}
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

    test "rejects unsupported schema formats at compile time" do
      assert_raise CompileError,
                   ~r/must be a Zoi schema or NimbleOptions keyword-list schema/,
                   fn ->
                     defmodule InvalidSchemaSignal do
                       use Jido.Signal,
                         type: "invalid.schema.signal",
                         schema: :not_a_schema
                     end
                   end
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

  def counted_options(counter) do
    Agent.update(counter, &(&1 + 1))
    [type: "counted.options.signal", schema: Zoi.object(%{value: Zoi.integer()})]
  end

  def counted_schema(counter) do
    Agent.update(counter, &(&1 + 1))
    Zoi.object(%{value: Zoi.integer()})
  end

  defp unique_module(prefix) do
    Module.concat(__MODULE__, "#{prefix}#{System.unique_integer([:positive])}")
  end

  defp create_module(module, quoted) do
    Module.create(module, quoted, Macro.Env.location(__ENV__))
  end
end
