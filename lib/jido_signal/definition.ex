defmodule Jido.Signal.Definition do
  @moduledoc false

  @default_data_schema Zoi.any()
  @config_schema Zoi.keyword(
                   [
                     type: Zoi.string() |> Zoi.required(),
                     default_source: Zoi.string(),
                     datacontenttype: Zoi.string(),
                     dataschema: Zoi.string(),
                     schema: Zoi.any() |> Zoi.default(@default_data_schema)
                   ],
                   unrecognized_keys: :error
                 )

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
              message =
                Jido.Signal.Error.format_zoi_config_error(error, "Signal", __MODULE__)

              raise CompileError,
                description: message,
                file: __ENV__.file,
                line: __ENV__.line
          end

        {:error, error} ->
          message = Jido.Signal.Error.format_zoi_config_error(error, "Signal", __MODULE__)

          raise CompileError,
            description: message,
            file: __ENV__.file,
            line: __ENV__.line
      end

      @doc "Returns the Signal type."
      def type, do: @signal_options[:type]

      @doc "Returns the default source, if one is configured."
      def default_source, do: @signal_options[:default_source]

      @doc "Returns the configured data content type."
      def datacontenttype, do: @signal_options[:datacontenttype]

      @doc "Returns the configured data schema URI."
      def dataschema, do: @signal_options[:dataschema]

      @doc "Returns the static Zoi data schema."
      def schema, do: @signal_data_schema

      @doc "Returns the typed Signal metadata."
      def to_json do
        %{
          datacontenttype: datacontenttype(),
          dataschema: dataschema(),
          default_source: default_source(),
          schema: schema(),
          type: type()
        }
      end

      @doc false
      def __signal_metadata__, do: to_json()

      @doc "Validates data with the static Zoi schema."
      def validate_data(data) do
        case Jido.Signal.Schema.validate(schema(), data) do
          {:ok, validated_data} ->
            {:ok, validated_data}

          {:error, error} ->
            {:error, Jido.Signal.Error.format_zoi_validation_error(error, "Signal", __MODULE__)}
        end
      end

      @doc "Creates a Signal with the configured type and validated data."
      def new(data \\ %{}, opts \\ []) when is_list(opts) or is_map(opts) do
        with {:ok, validated_data} <- validate_data(data) do
          attrs =
            opts
            |> Map.new()
            |> Map.put_new(:source, default_source())
            |> Map.put_new(:datacontenttype, datacontenttype())
            |> Map.put_new(:dataschema, dataschema())
            |> Enum.reject(fn {_key, value} -> is_nil(value) end)
            |> Map.new()
            |> Map.put(:type, type())
            |> Map.put(:data, validated_data)

          Jido.Signal.new(attrs)
        end
      end

      @doc "Creates a Signal and raises when the data or envelope is invalid."
      def new!(data \\ %{}, opts \\ []) do
        case new(data, opts) do
          {:ok, signal} -> signal
          {:error, reason} -> raise RuntimeError, reason
        end
      end
    end
  end
end
