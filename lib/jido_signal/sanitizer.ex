defmodule Jido.Signal.Sanitizer do
  @moduledoc false

  alias Jido.Signal

  @type profile :: :telemetry | :transport

  @profiles %{
    telemetry: %{max_depth: 3, max_items: 10, max_binary: 160, preview: 240},
    transport: %{max_depth: 6, max_items: 50, max_binary: 1024, preview: 512}
  }

  @redacted "[REDACTED]"
  @sensitive_keys MapSet.new(~w[
    access_token api_key authorization client_secret cookie credential passphrase password
    private_key proxy_authorization refresh_token secret set_cookie signature token
    webhook_secret webhook_signature x_api_key x_webhook_signature
  ])

  @doc "Sanitizes a value for a telemetry or transport boundary."
  @spec sanitize(term(), profile()) :: term()
  def sanitize(value, profile) when profile in [:telemetry, :transport] do
    sanitize(value, profile, Map.fetch!(@profiles, profile), 0)
  end

  @doc "Returns a bounded and safe preview for a log message."
  @spec preview(term(), profile(), keyword()) :: String.t()
  def preview(value, profile \\ :telemetry, opts \\ [])
      when profile in [:telemetry, :transport] do
    profile_opts = Map.fetch!(@profiles, profile)

    max_length =
      case Keyword.get(opts, :max_length, profile_opts.preview) do
        length when is_integer(length) and length >= 0 -> length
        _invalid -> profile_opts.preview
      end

    value
    |> sanitize(profile)
    |> inspect(pretty: false, limit: :infinity, printable_limit: :infinity)
    |> truncate(max_length)
  end

  defp sanitize(value, _profile, _opts, _depth)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value),
       do: value

  defp sanitize(value, :telemetry, _opts, _depth) when is_atom(value), do: value
  defp sanitize(value, :transport, _opts, _depth) when is_atom(value), do: Atom.to_string(value)

  defp sanitize(value, profile, opts, _depth) when is_binary(value) do
    if String.valid?(value) do
      truncate(value, opts.max_binary)
    else
      binary_summary(value, profile, opts.max_binary)
    end
  end

  defp sanitize(%Date{} = value, _profile, _opts, _depth), do: Date.to_iso8601(value)
  defp sanitize(%DateTime{} = value, _profile, _opts, _depth), do: DateTime.to_iso8601(value)

  defp sanitize(%NaiveDateTime{} = value, _profile, _opts, _depth),
    do: NaiveDateTime.to_iso8601(value)

  defp sanitize(%Time{} = value, _profile, _opts, _depth), do: Time.to_iso8601(value)

  defp sanitize(%URI{} = value, _profile, _opts, _depth) do
    value
    |> Map.merge(%{userinfo: nil, query: nil, fragment: nil})
    |> URI.to_string()
  end

  defp sanitize(%Signal{} = value, profile, opts, depth) do
    base =
      %{
        id: value.id,
        type: value.type,
        source: value.source,
        subject: value.subject,
        datacontenttype: value.datacontenttype,
        extensions: Map.keys(value.extensions || %{})
      }
      |> Map.reject(fn {_key, item} -> is_nil(item) end)

    case profile do
      :telemetry ->
        base

      :transport ->
        base
        |> Map.put(:data, sanitize(value.data, profile, opts, depth + 1))
        |> string_keys()
        |> Map.put("__struct__", inspect(Signal))
    end
  end

  defp sanitize(value, profile, opts, depth) when is_exception(value) do
    fields = value |> Map.from_struct() |> Map.drop([:__exception__, :__struct__, :message])
    base = boundary_map(profile, module: inspect(value.__struct__))

    if map_size(fields) == 0 do
      base
    else
      Map.put(base, boundary_key(profile, :details), sanitize(fields, profile, opts, depth + 1))
    end
  end

  defp sanitize(value, profile, opts, depth) when is_struct(value) do
    module = value.__struct__
    fields = Map.from_struct(value)

    condensed =
      fields
      |> Enum.filter(fn {key, item} ->
        scalar?(item) or key in [:id, :name, :path, :type, :source, :target, :status]
      end)
      |> Map.new()

    base =
      if map_size(condensed) == 0,
        do: %{summary: %{summary: :list, count: map_size(fields)}},
        else: condensed

    base
    |> sanitize(profile, opts, depth + 1)
    |> Map.put(boundary_key(profile, :__struct__), inspect(module))
  end

  defp sanitize(value, profile, opts, depth) when is_map(value) do
    if depth >= opts.max_depth do
      collection_summary(value, profile)
    else
      entries = value |> Map.to_list() |> Enum.sort_by(fn {key, _item} -> key_token(key) end)
      {entries, truncated?} = bounded(entries, opts.max_items)

      sanitized =
        Map.new(entries, fn {key, item} ->
          item =
            if sensitive_key?(key), do: @redacted, else: sanitize(item, profile, opts, depth + 1)

          {boundary_key(profile, key), item}
        end)

      mark_map_truncation(sanitized, truncated?, map_size(value), profile)
    end
  end

  defp sanitize(value, profile, opts, depth) when is_list(value) do
    cond do
      value != [] and (Keyword.keyword?(value) or key_value_list?(value)) ->
        sanitize(Map.new(value), profile, opts, depth)

      depth >= opts.max_depth ->
        collection_summary(value, profile)

      true ->
        {items, truncated?} = bounded(value, opts.max_items)
        items = Enum.map(items, &sanitize(&1, profile, opts, depth + 1))
        mark_list_truncation(items, truncated?, length(value), profile)
    end
  end

  defp sanitize(value, profile, opts, depth) when is_tuple(value) do
    if depth >= opts.max_depth do
      collection_summary(value, profile)
    else
      {items, truncated?} = value |> Tuple.to_list() |> bounded(opts.max_items)
      items = Enum.map(items, &sanitize(&1, profile, opts, depth + 1))
      items = mark_list_truncation(items, truncated?, tuple_size(value), profile)

      case profile do
        :telemetry -> List.to_tuple(items)
        :transport -> %{"__type__" => "tuple", "items" => items}
      end
    end
  end

  defp sanitize(value, :telemetry, _opts, _depth)
       when is_pid(value) or is_reference(value) or is_function(value) or is_port(value) or
              is_bitstring(value),
       do: inspect(value)

  defp sanitize(value, :transport, _opts, _depth)
       when is_pid(value) or is_reference(value) or is_function(value) or is_port(value) or
              is_bitstring(value),
       do: %{"__type__" => value_type(value), "value" => inspect(value)}

  defp sanitize(value, _profile, _opts, _depth), do: inspect(value)

  defp binary_summary(value, :telemetry, max_binary) do
    %{
      __type__: :binary,
      bytes: byte_size(value),
      preview: value |> Base.encode64() |> truncate(max_binary)
    }
  end

  defp binary_summary(value, :transport, max_binary) do
    %{
      "__type__" => "binary",
      "bytes" => byte_size(value),
      "preview" => value |> Base.encode64() |> truncate(max_binary)
    }
  end

  defp collection_summary(value, profile) do
    {type, size_key, size} =
      cond do
        is_map(value) -> {:map, :size, map_size(value)}
        is_list(value) -> {:list, :count, length(value)}
        is_tuple(value) -> {:tuple, :size, tuple_size(value)}
      end

    boundary_map(profile, [summary: boundary_value(profile, type)], {size_key, size})
  end

  defp mark_map_truncation(map, false, _size, _profile), do: map

  defp mark_map_truncation(map, true, size, profile) do
    marker = boundary_map(profile, count: size)
    Map.put(map, boundary_key(profile, :__truncated__), marker)
  end

  defp mark_list_truncation(items, false, _size, _profile), do: items

  defp mark_list_truncation(items, true, size, :telemetry) do
    items ++ ["... (#{size - length(items)} more)"]
  end

  defp mark_list_truncation(items, true, size, :transport) do
    items ++ [%{"__truncated__" => %{"count" => size}}]
  end

  defp bounded(enumerable, limit) do
    items = Enum.take(enumerable, limit + 1)
    {Enum.take(items, limit), length(items) > limit}
  end

  defp boundary_map(profile, entries) do
    Map.new(entries, fn {key, value} ->
      {boundary_key(profile, key), boundary_value(profile, value)}
    end)
  end

  defp boundary_map(profile, entries, {key, value}) do
    Map.put(boundary_map(profile, entries), boundary_key(profile, key), value)
  end

  defp boundary_key(:telemetry, key) when is_atom(key), do: key
  defp boundary_key(_profile, key), do: key_token(key)

  defp boundary_value(:transport, value) when is_atom(value), do: Atom.to_string(value)
  defp boundary_value(_profile, value), do: value

  defp key_token(key) when is_atom(key), do: Atom.to_string(key)

  defp key_token(key) when is_binary(key) do
    if String.valid?(key), do: key, else: "base64:" <> Base.encode64(key)
  end

  defp key_token(key), do: inspect(key)

  defp sensitive_key?(key) do
    key = key |> key_token() |> String.downcase() |> String.replace("-", "_")

    MapSet.member?(@sensitive_keys, key) or
      MapSet.member?(@sensitive_keys, String.trim_leading(key, "x_"))
  end

  defp key_value_list?(list) do
    Enum.all?(list, fn
      {key, _value} when is_atom(key) or is_binary(key) -> true
      _item -> false
    end)
  end

  defp truncate(value, limit) when byte_size(value) <= limit, do: value

  defp truncate(value, limit) do
    value
    |> valid_prefix(limit)
    |> Kernel.<>("...")
  end

  defp valid_prefix(_value, 0), do: ""

  defp valid_prefix(value, size) do
    prefix = binary_part(value, 0, size)

    if String.valid?(value) and not String.valid?(prefix),
      do: valid_prefix(value, size - 1),
      else: prefix
  end

  defp string_keys(map), do: Map.new(map, fn {key, value} -> {key_token(key), value} end)

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
end
