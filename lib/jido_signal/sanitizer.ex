defmodule Jido.Signal.Sanitizer do
  @moduledoc """
  Shared sanitization profiles for observability and transport boundaries.

  Use `:telemetry` when values are heading to logs or telemetry metadata.
  Use `:transport` when values are crossing a public, serialized boundary.
  """

  alias Jido.Signal

  @type profile :: :telemetry | :transport

  @telemetry_opts %{max_depth: 3, max_items: 10, max_binary: 160}
  @transport_opts %{max_depth: 6, max_items: 50, max_binary: 1024}

  @redacted "[REDACTED]"
  @sensitive_keys MapSet.new([
                    "access_token",
                    "api_key",
                    "authorization",
                    "client_secret",
                    "cookie",
                    "passphrase",
                    "password",
                    "private_key",
                    "refresh_token",
                    "secret",
                    "set_cookie",
                    "token",
                    "webhook_secret"
                  ])

  @doc """
  Sanitizes a value for the requested boundary profile.
  """
  @spec sanitize(term(), profile()) :: term()
  def sanitize(value, profile) when profile in [:telemetry, :transport] do
    do_sanitize(value, profile, profile_opts(profile), 0)
  end

  @doc """
  Returns an inspect-safe, bounded preview string for logs.
  """
  @spec preview(term(), profile(), keyword()) :: String.t()
  def preview(value, profile \\ :telemetry, opts \\ [])
      when profile in [:telemetry, :transport] do
    max_length = Keyword.get(opts, :max_length, default_preview_length(profile))

    value
    |> sanitize(profile)
    |> Kernel.inspect(pretty: false, limit: :infinity, printable_limit: :infinity)
    |> truncate_binary(max_length)
  end

  defp do_sanitize(value, _profile, _opts, _depth)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value) do
    value
  end

  defp do_sanitize(value, :telemetry, _opts, _depth) when is_atom(value), do: value

  defp do_sanitize(value, :transport, _opts, _depth) when is_atom(value),
    do: Atom.to_string(value)

  defp do_sanitize(value, profile, %{max_binary: max_binary}, _depth) when is_binary(value) do
    case profile do
      :telemetry ->
        truncate_binary(value, max_binary)

      :transport ->
        if String.valid?(value) do
          truncate_binary(value, max_binary)
        else
          %{
            "__type__" => "binary",
            "bytes" => byte_size(value),
            "preview" => value |> Base.encode64() |> truncate_binary(max_binary)
          }
        end
    end
  end

  defp do_sanitize(value, profile, opts, depth) when is_list(value) do
    cond do
      Keyword.keyword?(value) ->
        sanitize_map(Map.new(value), profile, opts, depth)

      depth >= opts.max_depth ->
        summarize_collection(value, profile)

      true ->
        {items, truncated?} = take_bounded(value, opts.max_items)

        sanitized_items =
          Enum.map(items, &do_sanitize(&1, profile, opts, depth + 1))

        append_list_truncation_marker(sanitized_items, truncated?, length(value), profile)
    end
  end

  defp do_sanitize(value, profile, opts, depth) when is_map(value) do
    cond do
      match?(%Date{}, value) ->
        Date.to_iso8601(value)

      match?(%Time{}, value) ->
        Time.to_iso8601(value)

      match?(%NaiveDateTime{}, value) ->
        NaiveDateTime.to_iso8601(value)

      match?(%DateTime{}, value) ->
        DateTime.to_iso8601(value)

      match?(%URI{}, value) ->
        URI.to_string(value)

      match?(%Signal{}, value) ->
        sanitize_signal(value, profile, opts, depth)

      is_exception(value) ->
        sanitize_exception(value, profile, opts, depth)

      is_struct(value) ->
        sanitize_struct(value, profile, opts, depth)

      true ->
        sanitize_map(value, profile, opts, depth)
    end
  end

  defp do_sanitize(value, :telemetry, _opts, _depth) when is_pid(value) or is_reference(value) do
    inspect(value)
  end

  defp do_sanitize(value, :transport, _opts, _depth) when is_pid(value) or is_reference(value) do
    %{"__type__" => value_type(value), "value" => inspect(value)}
  end

  defp do_sanitize(value, :telemetry, _opts, _depth) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&sanitize(&1, :telemetry))
    |> List.to_tuple()
  end

  defp do_sanitize(value, :transport, opts, depth) when is_tuple(value) do
    %{
      "__type__" => "tuple",
      "items" =>
        value
        |> Tuple.to_list()
        |> Enum.map(&do_sanitize(&1, :transport, opts, depth + 1))
    }
  end

  defp do_sanitize(value, profile, _opts, _depth)
       when is_function(value) or is_port(value) or is_bitstring(value) do
    case profile do
      :telemetry -> inspect(value)
      :transport -> %{"__type__" => value_type(value), "value" => inspect(value)}
    end
  end

  defp do_sanitize(value, _profile, _opts, _depth), do: inspect(value)

  defp sanitize_signal(%Signal{} = signal, profile, opts, depth) do
    base =
      %{
        id: signal.id,
        type: signal.type,
        source: signal.source,
        subject: signal.subject,
        datacontenttype: signal.datacontenttype,
        extensions: Map.keys(signal.extensions || %{})
      }
      |> compact_map()

    case profile do
      :telemetry ->
        base

      :transport ->
        base
        |> Map.put(:data, do_sanitize(signal.data, :transport, opts, depth + 1))
        |> stringify_keys()
        |> Map.put("__struct__", inspect(Signal))
    end
  end

  defp sanitize_exception(exception, profile, opts, depth) do
    fields =
      exception
      |> Map.from_struct()
      |> Map.drop([:__exception__, :__struct__])

    base = %{
      module: inspect(exception.__struct__),
      message: Exception.message(exception)
    }

    details =
      if map_size(fields) == 0 do
        %{}
      else
        do_sanitize(fields, profile, opts, depth + 1)
      end

    case profile do
      :telemetry ->
        Map.put(base, :details, details)

      :transport ->
        base
        |> Map.put(:details, details)
        |> stringify_keys()
    end
  end

  defp sanitize_struct(struct, profile, opts, depth) do
    module = struct.__struct__
    fields = Map.from_struct(struct)

    condensed =
      fields
      |> Enum.filter(fn {key, value} ->
        scalar?(value) or key in [:id, :name, :path, :type, :source, :target, :status]
      end)
      |> Enum.into(%{})

    base =
      if map_size(condensed) > 0 do
        condensed
      else
        %{summary: summarize_collection(Map.keys(fields), :telemetry)}
      end

    sanitized = do_sanitize(base, profile, opts, depth + 1)

    case profile do
      :telemetry ->
        Map.put(sanitized, :__struct__, inspect(module))

      :transport ->
        sanitized
        |> stringify_keys()
        |> Map.put("__struct__", inspect(module))
    end
  end

  defp sanitize_map(map, profile, opts, depth) do
    cond do
      depth >= opts.max_depth ->
        summarize_collection(map, profile)

      true ->
        map
        |> Map.to_list()
        |> Enum.sort_by(fn {key, _value} -> key_sort_token(key) end)
        |> take_bounded(opts.max_items)
        |> then(fn {items, truncated?} ->
          sanitized =
            Enum.reduce(items, empty_map(profile), fn {key, value}, acc ->
              sanitized_key = sanitize_key(key, profile)

              sanitized_value =
                if sensitive_key?(key) do
                  redacted_value(profile)
                else
                  do_sanitize(value, profile, opts, depth + 1)
                end

              Map.put(acc, sanitized_key, sanitized_value)
            end)

          maybe_mark_map_truncation(sanitized, truncated?, map_size(map), profile)
        end)
    end
  end

  defp empty_map(:telemetry), do: %{}
  defp empty_map(:transport), do: %{}

  defp maybe_mark_map_truncation(map, false, _original_size, _profile), do: map

  defp maybe_mark_map_truncation(map, true, original_size, :telemetry) do
    Map.put(map, :__truncated__, %{count: original_size})
  end

  defp maybe_mark_map_truncation(map, true, original_size, :transport) do
    Map.put(map, "__truncated__", %{"count" => original_size})
  end

  defp append_list_truncation_marker(items, false, _original_size, _profile), do: items

  defp append_list_truncation_marker(items, true, original_size, :telemetry) do
    items ++ ["... (#{original_size - length(items)} more)"]
  end

  defp append_list_truncation_marker(items, true, original_size, :transport) do
    items ++ [%{"__truncated__" => %{"count" => original_size}}]
  end

  defp take_bounded(enumerable, limit) do
    list = Enum.take(enumerable, limit + 1)
    truncated? = length(list) > limit
    {Enum.take(list, limit), truncated?}
  end

  defp sanitize_key(key, :telemetry) when is_atom(key), do: key
  defp sanitize_key(key, :telemetry), do: key_sort_token(key)
  defp sanitize_key(key, :transport), do: key_sort_token(key)

  defp key_sort_token(key) when is_atom(key), do: Atom.to_string(key)
  defp key_sort_token(key) when is_binary(key), do: key
  defp key_sort_token(key), do: inspect(key)

  defp sensitive_key?(key) do
    key = key |> key_sort_token() |> String.downcase()
    MapSet.member?(@sensitive_keys, key)
  end

  defp summarize_collection(collection, :telemetry) when is_map(collection) do
    %{summary: :map, size: map_size(collection)}
  end

  defp summarize_collection(collection, :telemetry) when is_list(collection) do
    %{summary: :list, count: length(collection)}
  end

  defp summarize_collection(collection, :transport) when is_map(collection) do
    %{"summary" => "map", "size" => map_size(collection)}
  end

  defp summarize_collection(collection, :transport) when is_list(collection) do
    %{"summary" => "list", "count" => length(collection)}
  end

  defp summarize_collection(value, :telemetry) do
    %{summary: value_type(value)}
  end

  defp summarize_collection(value, :transport) do
    %{"summary" => value_type(value)}
  end

  defp profile_opts(:telemetry), do: @telemetry_opts
  defp profile_opts(:transport), do: @transport_opts

  defp default_preview_length(:telemetry), do: 240
  defp default_preview_length(:transport), do: 512

  defp redacted_value(:telemetry), do: @redacted
  defp redacted_value(:transport), do: @redacted

  defp truncate_binary(value, max_binary) when byte_size(value) <= max_binary, do: value
  defp truncate_binary(value, max_binary), do: binary_part(value, 0, max_binary) <> "..."

  defp compact_map(map) do
    Enum.reject(map, fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {key_sort_token(key), value} end)
  end

  defp scalar?(value)
       when is_nil(value) or is_boolean(value) or is_atom(value) or is_binary(value) or
              is_integer(value) or is_float(value),
       do: true

  defp scalar?(_value), do: false

  defp value_type(value) when is_pid(value), do: "pid"
  defp value_type(value) when is_reference(value), do: "reference"
  defp value_type(value) when is_function(value), do: "function"
  defp value_type(value) when is_port(value), do: "port"
  defp value_type(value) when is_bitstring(value), do: "bitstring"
  defp value_type(value), do: value |> Kernel.inspect() |> truncate_binary(64)
end
