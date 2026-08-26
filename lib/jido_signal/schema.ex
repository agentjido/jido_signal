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
  @spec ensure_static_schema!(term(), atom(), Macro.Env.t()) :: term() | no_return()
  def ensure_static_schema!(schema, option, env) do
    case validate_static_data(schema) do
      :ok ->
        :ok

      {:error, reason} ->
        raise CompileError,
          description:
            "#{inspect(option)} must be static module data; #{reason}. " <>
              "Use named MFA effects such as {Module, :function, args}",
          file: env.file,
          line: env.line
    end

    case escapable_static_schema?(schema) do
      true ->
        schema

      false ->
        raise CompileError,
          description:
            "#{inspect(option)} must be static module data that can be stored in the Signal module. " <>
              "Use named MFA effects such as {Module, :function, args}",
          file: env.file,
          line: env.line
    end
  end

  defp escapable_static_schema?(schema) do
    Macro.escape(schema)
    true
  rescue
    ArgumentError -> false
  end

  @doc false
  @spec validate_static_data(term()) :: :ok | {:error, String.t()}
  def validate_static_data(term), do: static_schema_data(term, [])

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

  defp map_schema?(%Zoi.Types.Lazy{}), do: false

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

  defp static_schema_data(%Zoi.Types.Lazy{}, path),
    do: static_data_error("lazy schemas are not supported", path)

  defp static_schema_data(%Zoi.Types.Meta{} = meta, path) do
    with :ok <- static_schema_effects(meta.effects, path ++ [:effects]) do
      meta
      |> Map.from_struct()
      |> Map.delete(:effects)
      |> static_schema_data(path)
    end
  end

  defp static_schema_data(term, path) when is_function(term),
    do: static_data_error("anonymous functions are not supported", path)

  defp static_schema_data(term, path)
       when is_pid(term) or is_port(term) or is_reference(term),
       do: static_data_error("runtime process values are not supported", path)

  defp static_schema_data(term, path) when is_map(term) do
    term
    |> Map.to_list()
    |> Enum.sort_by(fn {key, _value} -> :erlang.term_to_binary(key) end)
    |> Enum.reduce_while(:ok, fn {key, value}, :ok ->
      with :ok <- static_schema_data(key, path ++ [:key]),
           :ok <- static_schema_data(value, path ++ [key]) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp static_schema_data(term, path) when is_list(term) do
    static_schema_list_data(term, path, 0)
  end

  defp static_schema_data(term, path) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
      case static_schema_data(value, path ++ [index]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp static_schema_data(_term, _path), do: :ok

  defp static_schema_effects(effects, path) when is_list(effects) do
    effects
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {effect, index}, :ok ->
      case static_schema_effect(effect, path ++ [index]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp static_schema_effects(_effects, path),
    do: static_data_error("schema effects must be a list", path)

  defp static_schema_effect({kind, {module, function, args}}, path)
       when kind in [:refine, :transform] and is_atom(module) and is_atom(function) and
              is_list(args) do
    static_schema_data(args, path ++ [kind, :args])
  end

  defp static_schema_effect({kind, effect}, path)
       when kind in [:refine, :transform] and is_function(effect) do
    static_data_error("anonymous functions are not supported", path)
  end

  defp static_schema_effect(_effect, path) do
    static_data_error(
      "custom schema effects must use {Module, :function, args} MFA values",
      path
    )
  end

  defp static_schema_list_data([], _path, _index), do: :ok

  defp static_schema_list_data([value | rest], path, index) when is_list(rest) do
    case static_schema_data(value, path ++ [index]) do
      :ok -> static_schema_list_data(rest, path, index + 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp static_schema_list_data([value | _tail], path, index) do
    with :ok <- static_schema_data(value, path ++ [index]) do
      static_data_error("improper list tails are not supported", path ++ [index + 1])
    end
  end

  defp static_data_error(reason, []), do: {:error, reason}
  defp static_data_error(reason, path), do: {:error, "#{reason} at #{inspect(path)}"}
end
