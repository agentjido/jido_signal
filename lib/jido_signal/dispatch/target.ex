defmodule Jido.Signal.Dispatch.Target do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              adapter: Zoi.atom(),
              module: Zoi.any() |> Zoi.nullable(),
              opts: Zoi.list()
            }
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec new(atom(), module() | nil, keyword()) :: {:ok, t()} | {:error, term()}
  def new(adapter, module, opts) do
    Zoi.parse(@schema, %__MODULE__{adapter: adapter, module: module, opts: opts})
  end

  @spec to_tuple(t()) :: {atom(), keyword()}
  def to_tuple(%__MODULE__{adapter: adapter, opts: opts}), do: {adapter, opts}
end
