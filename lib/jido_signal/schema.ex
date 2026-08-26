defmodule Jido.Signal.Schema do
  @moduledoc false

  @type t :: Zoi.schema()
  @type schema_type :: :zoi | :unknown

  @doc false
  @spec schema_type(term()) :: schema_type()
  def schema_type(schema) do
    if zoi_schema?(schema), do: :zoi, else: :unknown
  end

  @doc false
  @spec validate_config_schema(term()) :: :ok | {:error, String.t()}
  def validate_config_schema(schema) do
    case schema_type(schema) do
      :zoi ->
        if map_schema?(schema) do
          :ok
        else
          {:error, "must accept map-shaped Signal data"}
        end

      :unknown ->
        {:error, "must be a Zoi schema"}
    end
  end

  @doc false
  @spec validate(t(), term()) :: {:ok, term()} | {:error, term()}
  def validate(schema, data) do
    case Zoi.parse(schema, data) do
      {:ok, validated_data} when is_map(validated_data) or is_struct(schema, Zoi.Types.Any) ->
        {:ok, validated_data}

      {:ok, _validated_data} ->
        {:error, "Zoi schema validation must return a map"}

      {:error, _errors} = error ->
        error
    end
  end

  defp map_schema?(%Zoi.Types.Map{}), do: true
  defp map_schema?(%Zoi.Types.Struct{}), do: true
  defp map_schema?(%Zoi.Types.Any{}), do: true
  defp map_schema?(%Zoi.Types.DiscriminatedUnion{}), do: true

  defp map_schema?(%Zoi.Types.Lazy{}), do: true

  defp map_schema?(%Zoi.Types.Literal{value: value}), do: is_map(value)
  defp map_schema?(%Zoi.Types.Default{inner: inner}), do: map_schema?(inner)

  defp map_schema?(%Zoi.Types.Union{schemas: schemas}),
    do: Enum.any?(schemas, &map_schema?/1)

  defp map_schema?(%Zoi.Types.Intersection{schemas: schemas}),
    do: Enum.all?(schemas, &map_schema?/1)

  defp map_schema?(%Zoi.Types.Codec{from: from, to: to}),
    do: map_schema?(from) and map_schema?(to)

  defp map_schema?(_schema), do: false

  defp zoi_schema?(schema) do
    is_struct(schema) and Zoi.Type.impl_for(schema) != nil
  rescue
    _exception -> false
  end
end
