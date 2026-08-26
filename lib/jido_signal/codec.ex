defmodule Jido.Signal.Codec do
  @moduledoc false

  alias Jido.Signal
  alias Jido.Signal.Context

  @core_names ~w[
    specversion id source type subject time
    datacontenttype dataschema data extensions
  ]
  @legacy_wire_version_key "jido_schema_version"
  @legacy_wire_versions [1, 2]

  @spec from_map(map()) :: {:ok, Signal.t()} | {:error, String.t()}
  def from_map(map) when is_map(map) do
    attrs = stringify_keys(map)

    with :ok <- validate_legacy_wire_version(attrs),
         {:ok, extensions} <- extract_extensions(attrs) do
      parse_signal(attrs, extensions)
    end
  end

  def from_map(_map), do: {:error, "parse error: expected a map"}

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

  defp parse_signal(attrs, extensions) do
    signal =
      struct(Signal,
        data: Map.get(attrs, "data"),
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
      "dataschema" => signal.dataschema,
      "data" => signal.data
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

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
