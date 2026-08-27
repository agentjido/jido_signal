defmodule Jido.Signal.Codec do
  @moduledoc false

  alias Jido.Signal
  alias Jido.Signal.Context

  @core_names ~w[
    specversion id source type subject time
    datacontenttype dataschema data data_base64 extensions
  ]
  @legacy_wire_version_key "jido_schema_version"
  @legacy_wire_versions [1, 2]

  @doc false
  @spec from_map(map()) :: {:ok, Signal.t()} | {:error, String.t()}
  def from_map(map) when is_map(map) do
    attrs = stringify_keys(map)

    with :ok <- validate_legacy_wire_version(attrs),
         {:ok, data} <- extract_data(attrs),
         {:ok, extensions} <- extract_extensions(attrs) do
      parse_signal(attrs, data, extensions)
    end
  end

  def from_map(_map), do: {:error, "parse error: expected a map"}

  @doc false
  @spec to_map(Signal.t()) :: map()
  def to_map(%Signal{} = signal) do
    extensions =
      case Context.normalize(signal.extensions) do
        {:ok, extensions} -> extensions
        {:error, reason} -> raise ArgumentError, "invalid Signal extensions: #{reason}"
      end

    signal
    |> core_map()
    |> Map.merge(extensions)
  end

  defp extract_extensions(attrs) do
    explicit = Map.get(attrs, "extensions", %{})
    unknown = Map.drop(attrs, @core_names ++ [@legacy_wire_version_key])

    with {:ok, explicit} <- Context.normalize(explicit),
         {:ok, unknown} <- Context.normalize(unknown) do
      {:ok, Map.merge(unknown, explicit)}
    else
      {:error, reason} -> {:error, "parse error: #{reason}"}
    end
  end

  defp parse_signal(attrs, data, extensions) do
    signal =
      struct(Signal,
        data: data,
        datacontenttype: Map.get(attrs, "datacontenttype"),
        dataschema: Map.get(attrs, "dataschema"),
        extensions: extensions,
        id: Map.get(attrs, "id"),
        source: Map.get(attrs, "source"),
        specversion: normalize_specversion(Map.get(attrs, "specversion")),
        subject: Map.get(attrs, "subject"),
        time: normalize_time(Map.get(attrs, "time")),
        type: Map.get(attrs, "type")
      )

    case Zoi.parse(Signal.schema(), signal) do
      {:ok, validated} -> {:ok, validated}
      {:error, errors} -> {:error, "parse error: #{Zoi.prettify_errors(errors)}"}
    end
  end

  defp core_map(signal) do
    %{
      "specversion" => signal.specversion,
      "id" => signal.id,
      "source" => signal.source,
      "type" => signal.type,
      "subject" => signal.subject,
      "time" => normalize_time(signal.time),
      "datacontenttype" => signal.datacontenttype,
      "dataschema" => signal.dataschema
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Map.merge(encode_data(signal.data))
  end

  defp encode_data(nil), do: %{}

  defp encode_data(data) do
    if json_data?(data) do
      %{"data" => data}
    else
      %{"data_base64" => data |> :erlang.term_to_binary() |> Base.encode64()}
    end
  end

  defp extract_data(attrs) do
    case {Map.fetch(attrs, "data"), Map.fetch(attrs, "data_base64")} do
      {{:ok, _data}, {:ok, _encoded}} ->
        {:error, "parse error: data and data_base64 are mutually exclusive"}

      {{:ok, data}, :error} ->
        {:ok, data}

      {:error, {:ok, encoded}} ->
        decode_data_base64(encoded)

      {:error, :error} ->
        {:ok, nil}
    end
  end

  defp decode_data_base64(encoded) when is_binary(encoded) do
    with {:ok, binary} <- Base.decode64(encoded) do
      {:ok, :erlang.binary_to_term(binary, [:safe])}
    else
      :error -> {:error, "parse error: data_base64 must be valid Base64"}
    end
  rescue
    error in ArgumentError ->
      {:error,
       "parse error: data_base64 must contain a safe Erlang term: #{Exception.message(error)}"}
  end

  defp decode_data_base64(_encoded),
    do: {:error, "parse error: data_base64 must be a Base64 string"}

  defp json_data?(nil), do: true
  defp json_data?(value) when is_boolean(value) or is_number(value), do: true
  defp json_data?(value) when is_binary(value), do: String.valid?(value)
  defp json_data?([]), do: true
  defp json_data?([head | tail]), do: json_data?(head) and json_data?(tail)

  defp json_data?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {key, item} ->
      is_binary(key) and String.valid?(key) and json_data?(item)
    end)
  end

  defp json_data?(_value), do: false

  defp normalize_specversion("1.0.2"), do: "1.0"
  defp normalize_specversion(value), do: value

  defp normalize_time(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp normalize_time(time), do: time

  defp validate_legacy_wire_version(%{@legacy_wire_version_key => version})
       when version in @legacy_wire_versions,
       do: :ok

  defp validate_legacy_wire_version(%{@legacy_wire_version_key => nil}), do: :ok

  defp validate_legacy_wire_version(map)
       when not is_map_key(map, @legacy_wire_version_key),
       do: :ok

  defp validate_legacy_wire_version(%{@legacy_wire_version_key => version}) do
    {:error, "parse error: unsupported jido_schema_version #{inspect(version)}"}
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
