defmodule Jido.Signal.Definition do
  @moduledoc false

  @default_data_schema Zoi.any()
  @config_schema Zoi.keyword(
                   [
                     type: Zoi.string() |> Zoi.min(1) |> Zoi.required(),
                     default_source:
                       Zoi.string()
                       |> Zoi.min(1)
                       |> Zoi.refine({Jido.Signal, :validate_uri_reference, []}),
                     datacontenttype: Zoi.string() |> Zoi.min(1),
                     dataschema:
                       Zoi.string()
                       |> Zoi.min(1)
                       |> Zoi.refine({Jido.Signal, :validate_absolute_uri, []}),
                     schema: Zoi.any() |> Zoi.default(@default_data_schema)
                   ],
                   unrecognized_keys: :error
                 )

  @doc false
  @spec normalize_attrs(keyword() | map(), map()) :: {:ok, map()} | {:error, String.t()}
  def normalize_attrs(opts, defaults) when is_list(opts) or is_map(opts) do
    attrs =
      opts
      |> Map.new()
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    {:ok, Map.merge(defaults, attrs)}
  rescue
    _exception -> {:error, "expected Signal options to be a map or keyword list"}
  end

  def normalize_attrs(_opts, _defaults),
    do: {:error, "expected Signal options to be a map or keyword list"}

  @doc false
  def format_config_error(errors, module) when is_list(errors) do
    "Invalid configuration given to use Jido.Signal (#{module}): #{Zoi.prettify_errors(errors)}"
  end

  def format_config_error(error, module) when is_binary(error),
    do: "Invalid configuration given to use Jido.Signal (#{module}): #{error}"

  def format_config_error(error, module),
    do: "Invalid configuration given to use Jido.Signal (#{module}): #{inspect(error)}"

  @doc false
  def format_validation_error(errors, module) when is_list(errors) do
    "Invalid parameters for Signal (#{module}): #{Zoi.prettify_errors(errors)}"
  end

  def format_validation_error(error, module) when is_binary(error),
    do: "Invalid parameters for Signal (#{module}): #{error}"

  def format_validation_error(error, module),
    do: "Invalid parameters for Signal (#{module}): #{inspect(error)}"

  defmacro __using__(opts_ast) do
    escaped_config_schema = Macro.escape(@config_schema)

    quote location: :keep do
      raw_opts = unquote(opts_ast)

      case Zoi.parse(unquote(escaped_config_schema), raw_opts) do
        {:ok, validated_opts} ->
          schema =
            Jido.Signal.Schema.ensure_static_schema!(validated_opts[:schema], :schema, __ENV__)

          case Jido.Signal.Schema.validate_config_schema(schema) do
            :ok ->
              Module.put_attribute(__MODULE__, :signal_data_schema, schema)

              Module.put_attribute(
                __MODULE__,
                :signal_options,
                Keyword.delete(validated_opts, :schema)
              )

            {:error, error} ->
              message = Jido.Signal.Definition.format_config_error(error, __MODULE__)

              raise CompileError,
                description: message,
                file: __ENV__.file,
                line: __ENV__.line
          end

        {:error, error} ->
          message = Jido.Signal.Definition.format_config_error(error, __MODULE__)

          raise CompileError,
            description: message,
            file: __ENV__.file,
            line: __ENV__.line
      end

      @doc "Returns the Signal type."
      @spec type() :: String.t()
      def type, do: @signal_options[:type]

      @doc "Returns the default source, if one is configured."
      @spec default_source() :: String.t() | nil
      def default_source, do: @signal_options[:default_source]

      @doc "Returns the configured data content type."
      @spec datacontenttype() :: String.t() | nil
      def datacontenttype, do: @signal_options[:datacontenttype]

      @doc "Returns the configured data schema URI."
      @spec dataschema() :: String.t() | nil
      def dataschema, do: @signal_options[:dataschema]

      @doc "Returns the static Zoi data schema."
      @spec schema() :: Zoi.schema()
      def schema, do: @signal_data_schema

      @doc "Returns the typed Signal metadata."
      @spec metadata() :: map()
      def metadata do
        %{
          datacontenttype: datacontenttype(),
          dataschema: dataschema(),
          default_source: default_source(),
          schema: schema(),
          type: type()
        }
      end

      @doc false
      @spec __signal_metadata__() :: map()
      def __signal_metadata__, do: metadata()

      @doc "Validates data with the static Zoi schema."
      @spec validate_data(term()) :: {:ok, term()} | {:error, String.t()}
      def validate_data(data) do
        case Jido.Signal.Schema.validate(schema(), data) do
          {:ok, validated_data} ->
            {:ok, validated_data}

          {:error, error} ->
            {:error, Jido.Signal.Definition.format_validation_error(error, __MODULE__)}
        end
      end

      @doc "Creates a Signal with the configured type and validated data."
      @spec new(term(), keyword() | map()) ::
              {:ok, Jido.Signal.t()} | {:error, String.t()}
      def new(data \\ %{}, opts \\ []) do
        defaults =
          %{
            "source" => default_source(),
            "datacontenttype" => datacontenttype(),
            "dataschema" => dataschema()
          }
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.new()

        with {:ok, validated_data} <- validate_data(data),
             {:ok, attrs} <- Jido.Signal.Definition.normalize_attrs(opts, defaults) do
          attrs
          |> Map.put("type", type())
          |> Map.put("data", validated_data)
          |> Jido.Signal.new()
        end
      end

      @doc "Creates a Signal and raises when the data or envelope is invalid."
      @spec new!(term(), keyword() | map()) :: Jido.Signal.t() | no_return()
      def new!(data \\ %{}, opts \\ []) do
        case new(data, opts) do
          {:ok, signal} -> signal
          {:error, reason} -> raise ArgumentError, "invalid signal: #{reason}"
        end
      end
    end
  end
end
