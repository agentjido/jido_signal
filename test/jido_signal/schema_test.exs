defmodule Jido.Signal.SchemaTest do
  use ExUnit.Case, async: true

  alias Jido.Signal.Schema

  describe "default schemas" do
    test "accepts a map schema with a default and validates its data" do
      schema = Zoi.map(%{name: Zoi.string()}) |> Zoi.default(%{name: "fallback"})

      assert :ok = Schema.validate_config_schema(schema)
      assert {:ok, %{name: "value"}} = Schema.validate(schema, %{name: "value"})
      assert {:error, _} = Schema.validate(schema, %{name: 1})
    end

    test "rejects a scalar schema with a default" do
      schema = Zoi.string() |> Zoi.default("fallback")

      assert {:error, "must accept map-shaped Signal data"} =
               Schema.validate_config_schema(schema)
    end

    test "accepts a union with a default when a branch accepts maps" do
      schema = Zoi.union([Zoi.map(%{name: Zoi.string()}), Zoi.string()]) |> Zoi.default(%{})

      assert :ok = Schema.validate_config_schema(schema)
    end
  end
end
