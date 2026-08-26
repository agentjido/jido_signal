defmodule Jido.Signal.Bus.RecordedSignal do
  @moduledoc """
  A Signal record returned by Bus publish, replay, and durable delivery.

  `cursor` is the ordered Bus position. A durable consumer passes this cursor
  to `Jido.Signal.Bus.ack/3`.

  Signal wire encoding belongs to `Jido.Signal.Serialization`. This module is
  a value type and does not define a second serialization path.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              cursor: Zoi.integer() |> Zoi.min(1),
              type: Zoi.string(),
              created_at: Zoi.any(),
              signal: Zoi.any()
            }
          )

  @typedoc "A stored Signal with its Bus cursor"
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a recorded Signal."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema
end
