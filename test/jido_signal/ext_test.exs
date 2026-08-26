defmodule Jido.Signal.ExtTest do
  use ExUnit.Case, async: true

  # Define test extension modules for testing
  defmodule TestAuthExt do
    use Jido.Signal.Ext,
      namespace: "auth",
      schema:
        Zoi.object(%{
          user_id: Zoi.string(),
          roles: Zoi.array(Zoi.string()) |> Zoi.default([]),
          expires_at: Zoi.integer() |> Zoi.positive() |> Zoi.optional()
        })
  end

  defmodule TestTrackingExt do
    use Jido.Signal.Ext,
      namespace: "tracking",
      schema:
        Zoi.object(%{
          session_id: Zoi.string(),
          user_agent: Zoi.string() |> Zoi.optional(),
          ip_address: Zoi.string() |> Zoi.optional()
        })
  end

  defmodule TestSimpleExt do
    use Jido.Signal.Ext,
      namespace: "simple"

    # No schema - accepts any data
  end

  defmodule TestCustomSerializationExt do
    use Jido.Signal.Ext,
      namespace: "custom",
      schema: Zoi.object(%{content: Zoi.string()}),
      attributes: ["custom_content"]

    @impl Jido.Signal.Ext
    def to_attrs(data) do
      # Custom serialization: prefix with "custom_"
      %{custom_content: "custom_#{data.content}"}
    end

    @impl Jido.Signal.Ext
    def from_attrs(attrs) do
      custom_content = attrs[:custom_content]

      case custom_content do
        "custom_" <> actual_data -> %{content: actual_data}
        # This extension doesn't apply to this signal
        _ -> nil
      end
    end
  end

  # Test invalid namespace formats
  @invalid_namespaces [
    # uppercase
    "Auth",
    # hyphens
    "auth-ext",
    # underscores
    "auth_ext",
    # starts with number
    "123auth",
    # double dots
    "auth..ext",
    # ends with dot
    "auth.",
    # starts with dot
    ".auth",
    # empty
    "",
    # spaces
    "auth ext"
  ]

  describe "__using__ macro" do
    test "creates extension with required callbacks" do
      assert TestAuthExt.namespace() == "auth"
      assert %Zoi.Types.Map{} = TestAuthExt.schema()
      assert Enum.sort(TestAuthExt.attributes()) == ["expires_at", "roles", "user_id"]
    end

    test "provides default to_attrs and from_attrs implementations" do
      data = %{user_id: "123", roles: ["admin"]}

      assert TestAuthExt.to_attrs(data) == data
      assert TestAuthExt.from_attrs(data) == data
    end

    test "allows custom to_attrs and from_attrs implementations" do
      data = %{content: "test"}

      serialized = TestCustomSerializationExt.to_attrs(data)
      assert serialized == %{custom_content: "custom_test"}

      deserialized = TestCustomSerializationExt.from_attrs(serialized)
      assert deserialized == %{content: "test"}
    end

    test "extension without schema works" do
      assert TestSimpleExt.namespace() == "simple"
      assert %Zoi.Types.Any{} = TestSimpleExt.schema()
      assert TestSimpleExt.attributes() == []
    end

    test "validates namespace format at compile time" do
      for invalid_ns <- @invalid_namespaces do
        assert_raise CompileError, ~r/Extension namespace must be a lowercase string/, fn ->
          defmodule TestInvalidExt do
            use Jido.Signal.Ext,
              namespace: invalid_ns
          end
        end
      end
    end

    test "requires namespace option" do
      assert_raise CompileError, ~r/Extension must specify a :namespace option/, fn ->
        defmodule TestMissingNamespaceExt do
          use Jido.Signal.Ext,
            schema: Zoi.any()
        end
      end
    end

    test "validates schema at compile time" do
      assert_raise CompileError, ~r/Invalid extension schema/, fn ->
        defmodule TestInvalidSchemaExt do
          use Jido.Signal.Ext,
            namespace: "test",
            schema: :not_a_zoi_schema
        end
      end
    end
  end

  describe "data validation" do
    test "validates data according to schema" do
      valid_data = %{user_id: "123", roles: ["admin", "user"]}
      assert {:ok, validated} = TestAuthExt.validate_data(valid_data)
      assert validated.user_id == "123"
      assert validated.roles == ["admin", "user"]
    end

    test "applies default values from schema" do
      minimal_data = %{user_id: "123"}
      assert {:ok, validated} = TestAuthExt.validate_data(minimal_data)
      # default value
      assert validated.roles == []
    end

    test "validates required fields" do
      # missing required user_id
      invalid_data = %{roles: ["admin"]}
      assert {:error, error} = TestAuthExt.validate_data(invalid_data)
      assert error =~ "user_id"
      assert error =~ "required"
    end

    test "validates field types" do
      # user_id should be string
      invalid_data = %{user_id: 123, roles: ["admin"]}
      assert {:error, error} = TestAuthExt.validate_data(invalid_data)
      assert error =~ "expected string"
    end

    test "validates list types" do
      # roles should be list
      invalid_data = %{user_id: "123", roles: "admin"}
      assert {:error, error} = TestAuthExt.validate_data(invalid_data)
      assert error =~ "expected array"
    end

    test "extension without schema accepts any data" do
      any_data = %{anything: "goes", number: 42, list: [1, 2, 3]}
      assert {:ok, validated} = TestSimpleExt.validate_data(any_data)
      assert validated == any_data
    end

    test "handles empty data for extensions without schema" do
      assert {:ok, validated} = TestSimpleExt.validate_data(%{})
      assert validated == %{}
    end
  end

  describe "registry integration" do
    test "extensions auto-register themselves" do
      # Extensions should be registered during compilation
      assert {:ok, TestAuthExt} = Jido.Signal.Ext.Registry.get("auth")
      assert {:ok, TestTrackingExt} = Jido.Signal.Ext.Registry.get("tracking")
      assert {:ok, TestSimpleExt} = Jido.Signal.Ext.Registry.get("simple")
      assert {:ok, TestCustomSerializationExt} = Jido.Signal.Ext.Registry.get("custom")
    end

    test "can look up extension modules by namespace" do
      {:ok, auth_module} = Jido.Signal.Ext.Registry.get("auth")
      assert auth_module == TestAuthExt
      assert auth_module.namespace() == "auth"
    end

    test "returns error for unknown extensions" do
      assert {:error, :not_found} = Jido.Signal.Ext.Registry.get("nonexistent")
    end

    test "bang version raises for unknown extensions" do
      assert_raise ArgumentError, ~r/Extension not found: nonexistent/, fn ->
        Jido.Signal.Ext.Registry.get!("nonexistent")
      end
    end

    test "can enumerate all registered extensions" do
      extensions = Jido.Signal.Ext.Registry.all()
      namespaces = Enum.map(extensions, &elem(&1, 0))

      # Should contain at least our test extensions
      assert "auth" in namespaces
      assert "tracking" in namespaces
      assert "simple" in namespaces
      assert "custom" in namespaces
    end

    test "reports correct count of extensions" do
      count = Jido.Signal.Ext.Registry.count()
      # At least our test extensions
      assert count >= 4
    end

    test "checks if extensions are registered" do
      assert Jido.Signal.Ext.Registry.registered?("auth")
      assert Jido.Signal.Ext.Registry.registered?("tracking")
      refute Jido.Signal.Ext.Registry.registered?("nonexistent")
    end
  end

  describe "behavior compliance" do
    test "all test extensions implement required callbacks" do
      extensions = [TestAuthExt, TestTrackingExt, TestSimpleExt, TestCustomSerializationExt]

      for ext <- extensions do
        assert function_exported?(ext, :namespace, 0)
        assert function_exported?(ext, :schema, 0)
        assert function_exported?(ext, :to_attrs, 1)
        assert function_exported?(ext, :from_attrs, 1)
        assert function_exported?(ext, :validate_data, 1)
      end
    end

    test "namespace function returns correct values" do
      assert TestAuthExt.namespace() == "auth"
      assert TestTrackingExt.namespace() == "tracking"
      assert TestSimpleExt.namespace() == "simple"
      assert TestCustomSerializationExt.namespace() == "custom"
    end

    test "schema function returns a valid Zoi schema" do
      auth_schema = TestAuthExt.schema()
      assert %Zoi.Types.Map{} = auth_schema
      assert {:ok, %{user_id: "123", roles: []}} = Zoi.parse(auth_schema, %{user_id: "123"})
    end
  end

  describe "hierarchical namespaces" do
    defmodule TestHierarchicalExt do
      use Jido.Signal.Ext,
        namespace: "auth.oauth"
    end

    test "supports dot notation in namespaces" do
      assert TestHierarchicalExt.namespace() == "auth.oauth"
      assert {:ok, TestHierarchicalExt} = Jido.Signal.Ext.Registry.get("auth.oauth")
    end
  end

  describe "error handling" do
    test "provides meaningful validation error messages" do
      # Missing required field
      {:error, error1} = TestAuthExt.validate_data(%{roles: ["admin"]})
      assert error1 =~ "Extension"
      assert error1 =~ "user_id"
      assert error1 =~ "required"

      # Wrong type
      {:error, error2} = TestAuthExt.validate_data(%{user_id: 123})
      assert error2 =~ "Extension"
      assert error2 =~ "expected string"
    end

    test "validate_data rejects non-map data for an object schema" do
      kw_data = [user_id: "123", roles: ["admin"]]
      assert {:error, error} = TestAuthExt.validate_data(kw_data)
      assert error =~ "expected map"
    end
  end
end
