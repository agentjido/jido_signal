defmodule Jido.Signal.CustomTest do
  use ExUnit.Case, async: true

  alias Jido.Signal.ID

  defmodule UserCreated do
    use Jido.Signal,
      type: "user.created",
      default_source: "/accounts",
      datacontenttype: "application/json",
      dataschema: "https://example.com/schemas/user-created",
      schema:
        Zoi.object(%{
          user_id: Zoi.string(),
          email:
            Zoi.string()
            |> Zoi.refine({Jido.Signal.CustomTest, :valid_email, []}),
          count: Zoi.integer() |> Zoi.default(1)
        })
  end

  defmodule ExplicitSource do
    use Jido.Signal,
      type: "explicit.source",
      schema: Zoi.object(%{value: Zoi.string()})
  end

  describe "typed Signal construction" do
    test "uses configured envelope values and validates data" do
      assert {:ok, signal} =
               UserCreated.new(%{user_id: "123", email: "user@example.com"})

      assert signal.type == "user.created"
      assert signal.source == "/accounts"
      assert signal.specversion == "1.0"
      assert signal.time == nil
      assert signal.datacontenttype == "application/json"
      assert signal.dataschema == "https://example.com/schemas/user-created"
      assert signal.data.count == 1
      assert ID.valid?(signal.id)
    end

    test "supports an explicit source override" do
      assert {:ok, signal} =
               UserCreated.new(
                 %{user_id: "123", email: "user@example.com"},
                 source: "/imports"
               )

      assert signal.source == "/imports"
    end

    test "requires source when the definition has no default" do
      assert {:error, error} = ExplicitSource.new(%{value: "test"})
      assert error =~ "source"

      assert {:ok, signal} = ExplicitSource.new(%{value: "test"}, source: "/test")
      assert signal.source == "/test"
    end

    test "returns a useful Zoi validation error" do
      assert {:error, error} =
               UserCreated.new(%{user_id: "123", email: "not-an-email"})

      assert error =~ "email"
      assert error =~ "must contain @"
    end

    test "keeps type and data fixed by the definition" do
      assert {:ok, signal} =
               UserCreated.new(
                 %{user_id: "123", email: "user@example.com"},
                 type: "other.type",
                 data: %{other: true}
               )

      assert signal.type == "user.created"
      assert signal.data.user_id == "123"
    end

    test "exposes concise static metadata" do
      assert UserCreated.type() == "user.created"
      assert UserCreated.default_source() == "/accounts"
      assert %Zoi.Types.Map{} = UserCreated.schema()

      assert UserCreated.metadata() == %{
               type: "user.created",
               default_source: "/accounts",
               datacontenttype: "application/json",
               dataschema: "https://example.com/schemas/user-created",
               schema: UserCreated.schema()
             }
    end
  end

  describe "static Zoi schema checks" do
    test "accepts named MFA effects" do
      assert {:ok, data} =
               UserCreated.validate_data(%{user_id: "123", email: "user@example.com"})

      assert data.count == 1
    end

    test "rejects anonymous functions at compile time" do
      module = unique_module("AnonymousSchema")

      assert_raise CompileError, ~r/anonymous functions are not supported/, fn ->
        create_module(
          module,
          quote do
            use Jido.Signal,
              type: "anonymous.schema",
              default_source: "/test",
              schema:
                Zoi.object(%{
                  value: Zoi.string() |> Zoi.refine(fn _value, _opts -> :ok end)
                })
          end
        )
      end
    end

    test "rejects lazy schemas at compile time" do
      module = unique_module("LazySchema")

      assert_raise CompileError, ~r/lazy schemas are not supported/, fn ->
        create_module(
          module,
          quote do
            use Jido.Signal,
              type: "lazy.schema",
              default_source: "/test",
              schema: Zoi.lazy(fn -> Zoi.object(%{value: Zoi.string()}) end)
          end
        )
      end
    end

    test "rejects malformed Zoi effects at compile time" do
      module = unique_module("MalformedEffect")

      assert_raise CompileError, ~r/custom schema effects must use.*MFA/, fn ->
        create_module(
          module,
          quote do
            use Jido.Signal,
              type: "malformed.effect",
              default_source: "/test",
              schema:
                Zoi.object(%{
                  value: Zoi.string() |> Zoi.refine(:not_an_mfa)
                })
          end
        )
      end
    end

    test "validates envelope defaults at compile time" do
      for {suffix, opts} <- [
            {"EmptyType", [type: "", default_source: "/test"]},
            {"InvalidSource", [type: "invalid.source", default_source: "bad source"]},
            {"InvalidSchemaURI",
             [
               type: "invalid.schema.uri",
               default_source: "/test",
               dataschema: "/relative"
             ]}
          ] do
        module = unique_module(suffix)

        assert_raise CompileError, fn ->
          create_module(
            module,
            quote do
              use Jido.Signal, unquote(opts)
            end
          )
        end
      end
    end

    test "returns an error for invalid construction options" do
      assert {:error, error} =
               UserCreated.new(%{user_id: "123", email: "user@example.com"}, [:invalid])

      assert error =~ "options"
    end

    test "rejects non-Zoi schemas at compile time" do
      module = unique_module("InvalidSchema")

      assert_raise CompileError, ~r/must be a Zoi schema/, fn ->
        create_module(
          module,
          quote do
            use Jido.Signal,
              type: "invalid.schema",
              default_source: "/test",
              schema: :not_a_schema
          end
        )
      end
    end
  end

  def valid_email(email, _opts) do
    if String.contains?(email, "@"), do: :ok, else: {:error, "must contain @"}
  end

  defp create_module(module, body) do
    Module.create(module, body, Macro.Env.location(__ENV__))
  end

  defp unique_module(suffix) do
    Module.concat(__MODULE__, "#{suffix}#{System.unique_integer([:positive])}")
  end
end
