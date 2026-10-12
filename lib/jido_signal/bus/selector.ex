defmodule Jido.Signal.Bus.Selector do
  @moduledoc false

  @envelope_fields [
    :id,
    :source,
    :type,
    :specversion,
    :subject,
    :time,
    :datacontenttype,
    :dataschema
  ]
  @max_clauses 16
  @max_path_length 8
  @max_key_bytes 256
  @max_value_bytes 1_024
  @min_integer -9_223_372_036_854_775_808
  @max_integer 9_223_372_036_854_775_807

  @schema Zoi.any() |> Zoi.refine({__MODULE__, :validate_spec, []})

  @doc false
  @spec validate(term()) :: {:ok, Jido.Signal.Bus.selector()} | {:error, term()}
  def validate(selector) do
    case Zoi.parse(@schema, selector) do
      {:ok, selector} -> {:ok, selector}
      {:error, errors} -> {:error, {:invalid_selector, Zoi.prettify_errors(errors)}}
    end
  end

  @doc false
  def validate_spec([_ | _] = selector, _opts) do
    if valid_clauses?(selector, @max_clauses),
      do: :ok,
      else: {:error, "selector clauses, paths, or values are invalid or exceed their bounds"}
  end

  def validate_spec(_selector, _opts),
    do: {:error, "selector must be a non-empty list of {path, value} pairs"}

  @doc false
  @spec matches?(Jido.Signal.t(), Jido.Signal.Bus.selector()) :: boolean()
  def matches?(signal, selector) do
    Enum.all?(selector, fn {path, expected} ->
      case fetch_path(signal, path) do
        {:ok, value} -> value === expected
        :error -> false
      end
    end)
  end

  defp valid_clauses?([], _remaining), do: true

  defp valid_clauses?([{path, value} | rest], remaining) when remaining > 0 do
    valid_path?(path) and valid_value?(value) and valid_clauses?(rest, remaining - 1)
  end

  defp valid_clauses?(_clauses, _remaining), do: false

  defp valid_path?([field]) when field in @envelope_fields, do: true

  defp valid_path?([:data | keys]), do: valid_keys?(keys, @max_path_length - 1)

  defp valid_path?([:extensions, _ | _] = path),
    do: valid_keys?(tl(path), @max_path_length - 1)

  defp valid_path?(_path), do: false

  defp valid_keys?([], _remaining), do: true

  defp valid_keys?([key | rest], remaining) when remaining > 0 do
    valid_key?(key) and valid_keys?(rest, remaining - 1)
  end

  defp valid_keys?(_keys, _remaining), do: false

  defp valid_key?(key) when is_atom(key), do: true
  defp valid_key?(key) when is_binary(key), do: byte_size(key) <= @max_key_bytes
  defp valid_key?(_key), do: false

  defp valid_value?(value) when is_binary(value), do: byte_size(value) <= @max_value_bytes

  defp valid_value?(value) when is_integer(value),
    do: value >= @min_integer and value <= @max_integer

  defp valid_value?(value), do: is_float(value) or is_boolean(value) or is_nil(value)

  defp fetch_path(value, []), do: {:ok, value}

  defp fetch_path(value, [key | rest]) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, next} -> fetch_path(next, rest)
      :error -> :error
    end
  end

  defp fetch_path(_value, _path), do: :error
end
