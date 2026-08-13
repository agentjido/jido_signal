defmodule Jido.Signal.Schema do
  @moduledoc false

  @type t :: NimbleOptions.schema() | struct() | []
  @type schema_type :: :empty | :nimble_options | :zoi | :unknown

  @doc false
  @spec schema_type(term()) :: schema_type()
  def schema_type([]), do: :empty

  def schema_type(schema) when is_list(schema) do
    if Keyword.keyword?(schema), do: :nimble_options, else: :unknown
  end

  def schema_type(schema) do
    if zoi_schema?(schema), do: :zoi, else: :unknown
  end

  @doc false
  @spec validate_config_schema(term()) :: :ok | {:error, String.t()}
  def validate_config_schema(schema) do
    case schema_type(schema) do
      type when type in [:empty, :nimble_options] ->
        :ok

      :zoi ->
        if map_schema?(schema) do
          :ok
        else
          {:error, "must accept map-shaped Signal data"}
        end

      :unknown ->
        {:error, "must be a Zoi schema or NimbleOptions keyword-list schema"}
    end
  end

  @doc false
  @spec validate(t(), term()) :: {:ok, term()} | {:error, term()}
  def validate([], data), do: {:ok, data}

  def validate(schema, data) when is_list(schema) do
    data_options = if is_map(data), do: Map.to_list(data), else: data

    case NimbleOptions.validate(data_options, schema) do
      {:ok, validated_options} -> {:ok, Map.new(validated_options)}
      {:error, error} -> {:error, error}
    end
  end

  def validate(schema, data) do
    case Zoi.parse(schema, data) do
      {:ok, validated_data} when is_map(validated_data) ->
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

  defp map_schema?(%Zoi.Types.Lazy{} = schema) do
    case resolve_lazy(schema) do
      %Zoi.Types.Lazy{} -> false
      resolved_schema -> map_schema?(resolved_schema)
    end
  rescue
    _exception -> false
  end

  defp map_schema?(%Zoi.Types.Literal{value: value}), do: is_map(value)
  defp map_schema?(%Zoi.Types.Default{inner: inner}), do: map_schema?(inner)

  defp map_schema?(%Zoi.Types.Union{schemas: schemas}),
    do: Enum.any?(schemas, &map_schema?/1)

  defp map_schema?(%Zoi.Types.Intersection{schemas: schemas}),
    do: Enum.all?(schemas, &map_schema?/1)

  defp map_schema?(%Zoi.Types.Codec{from: from, to: to}),
    do: map_schema?(from) and map_schema?(to)

  defp map_schema?(_schema), do: false

  defp resolve_lazy(%Zoi.Types.Lazy{fun: {module, function, args}}),
    do: apply(module, function, args)

  defp resolve_lazy(%Zoi.Types.Lazy{fun: function}), do: function.()

  defp zoi_schema?(schema) do
    is_struct(schema) and Zoi.Type.impl_for(schema) != nil
  rescue
    _exception -> false
  end
end
