defmodule Jido.Signal.Bus.Subscriber do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              path: Zoi.string(),
              dispatch: Zoi.any(),
              persistent?: Zoi.default(Zoi.boolean(), false) |> Zoi.optional(),
              disconnected?: Zoi.default(Zoi.boolean(), false) |> Zoi.optional(),
              client_pid: Zoi.any() |> Zoi.nullable() |> Zoi.optional(),
              monitor_ref: Zoi.any() |> Zoi.nullable() |> Zoi.optional(),
              created_at: Zoi.any(),
              pending: Zoi.default(Zoi.map(), %{}) |> Zoi.optional(),
              last_seen_cursor: Zoi.default(Zoi.integer(), 0) |> Zoi.optional()
            }
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  def schema, do: @schema
end
