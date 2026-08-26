defmodule Jido.Signal.Bus.Subscriber do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              path: Zoi.string(),
              durable?: Zoi.default(Zoi.boolean(), false) |> Zoi.optional(),
              target: Zoi.any() |> Zoi.nullable() |> Zoi.optional(),
              monitor_ref: Zoi.any() |> Zoi.nullable() |> Zoi.optional(),
              cursor: Zoi.integer() |> Zoi.min(0),
              in_flight: Zoi.integer() |> Zoi.min(1) |> Zoi.nullable() |> Zoi.optional(),
              created_at: Zoi.any()
            }
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  def schema, do: @schema
end
