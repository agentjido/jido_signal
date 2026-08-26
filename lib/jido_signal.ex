defmodule Jido.Signal do
  @moduledoc """
  Defines the Jido event envelope.

  A Signal uses the CloudEvents 1.0 context attributes. Jido generates UUID7
  values for new Signal IDs. It does not infer the event source, event time, or
  data content type.

  The required attributes are `specversion`, `id`, `source`, and `type`.
  `specversion` is always `"1.0"` on output. A legacy `"1.0.2"` value is
  accepted on input and is normalized to `"1.0"`.

  Extension context attributes are optional flat metadata. Their names and
  values follow the CloudEvents rules. Put domain fields in `data` and validate
  them with a custom Signal module.

  The canonical map keeps JSON-safe values in `data`. It encodes binary and
  other Erlang-only values as an Erlang term binary in `data_base64`.

  ## Examples

      {:ok, signal} =
        Jido.Signal.new("user.created", %{user_id: "123"}, source: "/accounts")

      signal.specversion
      #=> "1.0"

      Jido.Signal.ID.valid?(signal.id)
      #=> true

  ## Custom Signal modules

      defmodule MyApp.UserCreated do
        use Jido.Signal,
          type: "user.created",
          default_source: "/accounts",
          schema:
            Zoi.object(%{
              user_id: Zoi.string()
            })
      end

  Custom schemas must be static module data. Zoi refinements, transforms, and
  other callbacks must use named `{Module, :function, args}` MFA values.
  Anonymous functions and lazy schemas are not accepted.
  """

  alias Jido.Signal.Context
  alias Jido.Signal.ID
  alias Jido.Signal.Codec
  alias Jido.Signal.Serialization

  @wire_version 3

  @signal_schema Zoi.struct(
                   __MODULE__,
                   %{
                     id: Zoi.string() |> Zoi.min(1),
                     source:
                       Zoi.string()
                       |> Zoi.min(1)
                       |> Zoi.refine({__MODULE__, :validate_uri_reference, []}),
                     type: Zoi.string() |> Zoi.min(1),
                     specversion: Zoi.default(Zoi.literal("1.0"), "1.0") |> Zoi.optional(),
                     subject: Zoi.string() |> Zoi.min(1) |> Zoi.nullable() |> Zoi.optional(),
                     time:
                       Zoi.string()
                       |> Zoi.refine({__MODULE__, :validate_rfc3339, []})
                       |> Zoi.nullable()
                       |> Zoi.optional(),
                     datacontenttype:
                       Zoi.string() |> Zoi.min(1) |> Zoi.nullable() |> Zoi.optional(),
                     dataschema:
                       Zoi.string()
                       |> Zoi.refine({__MODULE__, :validate_absolute_uri, []})
                       |> Zoi.nullable()
                       |> Zoi.optional(),
                     data: Zoi.any() |> Zoi.optional(),
                     extensions: Zoi.default(Zoi.map(), %{}) |> Zoi.optional()
                   }
                 )

  @type t :: unquote(Zoi.type_spec(@signal_schema))
  @enforce_keys Zoi.Struct.enforce_keys(@signal_schema)
  defstruct Zoi.Struct.struct_fields(@signal_schema)

  @doc "Returns the Zoi schema for the core Signal envelope."
  @spec schema() :: Zoi.schema()
  def schema, do: @signal_schema

  @doc "Returns the Jido Signal API wire generation."
  @spec wire_version() :: pos_integer()
  def wire_version, do: @wire_version

  @doc "Defines a custom Signal module with a static Zoi data schema."
  defmacro __using__(opts) do
    quote do
      use Jido.Signal.Definition, unquote(opts)
    end
  end

  @doc "Creates a Signal from an attribute map or keyword list."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    attrs
    |> stringify_keys()
    |> Map.put_new("id", ID.generate!())
    |> Map.put_new("specversion", "1.0")
    |> Codec.from_map()
  end

  def new(_attrs), do: {:error, "parse error: expected a map or keyword list"}

  @doc "Creates a Signal with an explicit type, data value, and attributes."
  @spec new(String.t(), term(), map() | keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(type, data, attrs \\ %{})

  def new(type, data, attrs) when is_binary(type) and (is_map(attrs) or is_list(attrs)) do
    attrs = Map.new(attrs)

    case Enum.find([:type, "type", :data, "data"], &Map.has_key?(attrs, &1)) do
      nil -> attrs |> Map.put(:type, type) |> Map.put(:data, data) |> new()
      key -> {:error, "attribute #{inspect(key)} must not be passed in attrs when calling new/3"}
    end
  end

  def new(_type, _data, _attrs) do
    {:error, "expected new/3 (type :: String.t(), data :: any(), attrs :: map/keyword)"}
  end

  @doc "Creates a Signal and raises when its envelope is invalid."
  @spec new!(map() | keyword()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, signal} -> signal
      {:error, reason} -> raise RuntimeError, reason
    end
  end

  @doc "Creates a Signal with explicit type and data, or raises when it is invalid."
  @spec new!(String.t(), term(), map() | keyword()) :: t() | no_return()
  def new!(type, data, attrs \\ %{}) do
    case new(type, data, attrs) do
      {:ok, signal} -> signal
      {:error, reason} -> raise ArgumentError, "invalid signal: #{reason}"
    end
  end

  @doc "Parses a complete CloudEvents structured-mode map."
  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  defdelegate from_map(map), to: Codec

  @doc "Returns the canonical CloudEvents structured-mode map."
  @spec to_map(t()) :: map()
  defdelegate to_map(signal), to: Codec

  @doc "Adds a CloudEvents extension context attribute."
  @spec put_context(t(), atom() | String.t(), Context.value()) ::
          {:ok, t()} | {:error, String.t()}
  defdelegate put_context(signal, name, value), to: Context, as: :put

  @doc "Gets a CloudEvents extension context attribute."
  @spec get_context(t(), atom() | String.t()) :: Context.value() | nil
  defdelegate get_context(signal, name), to: Context, as: :get

  @doc "Deletes a CloudEvents extension context attribute."
  @spec delete_context(t(), atom() | String.t()) :: t()
  defdelegate delete_context(signal, name), to: Context, as: :delete

  @doc "Lists the CloudEvents extension context attribute names."
  @spec list_context(t()) :: [String.t()]
  defdelegate list_context(signal), to: Context, as: :names

  @deprecated "Use put_context/3. Extension values are now flat CloudEvents values."
  defdelegate put_extension(signal, name, value), to: Context, as: :put

  @deprecated "Use get_context/2."
  defdelegate get_extension(signal, name), to: Context, as: :get

  @deprecated "Use delete_context/2."
  defdelegate delete_extension(signal, name), to: Context, as: :delete

  @deprecated "Use list_context/1."
  defdelegate list_extensions(signal), to: Context, as: :names

  @doc false
  def flatten_extensions(%__MODULE__{} = signal), do: to_map(signal)

  @doc false
  def inflate_extensions(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    core_names = ~w[specversion id source type subject time datacontenttype dataschema data]
    {Map.drop(attrs, core_names), Map.take(attrs, core_names)}
  end

  @doc "Serializes one Signal or a list of Signals as JSON or Erlang Term Format."
  defdelegate serialize(signal_or_signals, opts \\ []), to: Serialization

  @doc "Serializes one Signal or a list of Signals, or raises."
  def serialize!(signal_or_signals, opts \\ []) do
    case serialize(signal_or_signals, opts) do
      {:ok, binary} -> binary
      {:error, reason} -> raise RuntimeError, "serialization failed: #{inspect(reason)}"
    end
  end

  @doc "Deserializes one Signal or a list of Signals from JSON or Erlang Term Format."
  defdelegate deserialize(binary, opts \\ []), to: Serialization

  @doc false
  def validate_uri_reference(value, _opts) when is_binary(value) do
    case URI.new(value) do
      {:ok, _uri} -> :ok
      {:error, reason} -> {:error, "must be a URI-reference: #{inspect(reason)}"}
    end
  end

  @doc false
  def validate_absolute_uri(value, _opts) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) and scheme != "" -> :ok
      _result -> {:error, "must be an absolute URI"}
    end
  end

  @doc false
  def validate_rfc3339(value, _opts) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> :ok
      {:error, reason} -> {:error, "must be an RFC 3339 timestamp: #{inspect(reason)}"}
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
