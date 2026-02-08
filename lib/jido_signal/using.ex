defmodule Jido.Signal.Using do
  @moduledoc """
  Helper module containing macro code for `use Jido.Signal`.

  This module provides the `define_signal_functions/0` macro that generates
  all the necessary functions for a custom Signal module, including:

  - Accessor functions (`type/0`, `default_source/0`, etc.)
  - Constructor functions (`new/0`, `new/1`, `new/2`, `new!/0`, `new!/1`, `new!/2`)
  - Validation functions (`validate_data/1`)
  - Serialization helpers (`to_json/0`, `__signal_metadata__/0`)
  """

  alias __MODULE__, as: Using
  alias Jido.Signal.Error
  alias Jido.Signal.ID

  # Alias for internal use in macros
  @doc """
  Defines all signal-related functions in the calling module.

  This macro is called from `use Jido.Signal` and expects the `@validated_opts`
  module attribute to be set with the validated configuration options.
  """
  defmacro define_signal_functions do
    quote location: :keep do
      alias Jido.Signal.Using

      require Using

      Using.define_accessor_functions()
      Using.define_constructor_functions()
      Using.define_validation_functions()
      Using.define_signal_builder_functions()
      Using.define_caller_module_functions()
    end
  end

  @doc false
  defmacro define_accessor_functions do
    quote location: :keep do
      def type, do: @validated_opts[:type]
      def default_source, do: @validated_opts[:default_source]
      def datacontenttype, do: @validated_opts[:datacontenttype]
      def dataschema, do: @validated_opts[:dataschema]
      def schema, do: @validated_opts[:schema]

      def to_json do
        %{
          datacontenttype: @validated_opts[:datacontenttype],
          dataschema: @validated_opts[:dataschema],
          default_source: @validated_opts[:default_source],
          schema: @validated_opts[:schema],
          type: @validated_opts[:type]
        }
      end

      def __signal_metadata__ do
        to_json()
      end
    end
  end

  @doc false
  defmacro define_constructor_functions do
    quote location: :keep do
      @doc """
      Creates a new Signal instance with the configured type and validated data.

      ## Parameters

      - `data`: A map containing the Signal's data payload.
      - `opts`: Additional Signal options (source, subject, etc.)

      ## Returns

      `{:ok, Signal.t()}` if the data is valid, `{:error, String.t()}` otherwise.

      ## Examples

          iex> MySignal.new(%{user_id: "123", message: "Hello"})
          {:ok, %Jido.Signal{type: "my.custom.signal", data: %{user_id: "123", message: "Hello"}, ...}}

      """
      @spec new(map(), keyword()) :: {:ok, Jido.Signal.t()} | {:error, String.t()}
      def new(data \\ %{}, opts \\ []) do
        with {:ok, validated_data} <- validate_data(data),
             {:ok, signal_attrs} <- build_signal_attrs(validated_data, opts) do
          Jido.Signal.from_map(signal_attrs)
        end
      end

      @doc """
      Creates a new Signal instance, raising an error if invalid.

      ## Parameters

      - `data`: A map containing the Signal's data payload.
      - `opts`: Additional Signal options (source, subject, etc.)

      ## Returns

      `Signal.t()` if the data is valid.

      ## Raises

      `RuntimeError` if the data is invalid.

      ## Examples

          iex> MySignal.new!(%{user_id: "123", message: "Hello"})
          %Jido.Signal{type: "my.custom.signal", data: %{user_id: "123", message: "Hello"}, ...}

      """
      @spec new!(map(), keyword()) :: Jido.Signal.t() | no_return()
      def new!(data \\ %{}, opts \\ []) do
        case new(data, opts) do
          {:ok, signal} -> signal
          {:error, reason} -> raise reason
        end
      end
    end
  end

  @doc false
  defmacro define_validation_functions do
    quote location: :keep do
      alias Jido.Signal.Error

      @doc """
      Validates the data for the Signal according to its schema.

      ## Examples

          iex> MySignal.validate_data(%{user_id: "123", message: "Hello"})
          {:ok, %{user_id: "123", message: "Hello"}}

          iex> MySignal.validate_data(%{})
          {:error, "Invalid data for Signal: Required key :user_id not found"}

      """
      @spec validate_data(map()) :: {:ok, map()} | {:error, String.t()}
      def validate_data(data) do
        do_validate_data(@validated_opts[:schema], data)
      end

      defp do_validate_data([], data), do: {:ok, data}

      defp do_validate_data(schema, data) when is_list(schema) do
        case NimbleOptions.validate(Enum.to_list(data), schema) do
          {:ok, validated_data} ->
            {:ok, Map.new(validated_data)}

          {:error, %NimbleOptions.ValidationError{} = error} ->
            reason = Error.format_nimble_validation_error(error, "Signal", __MODULE__)
            {:error, reason}
        end
      end
    end
  end

  @doc false
  defmacro define_signal_builder_functions do
    quote location: :keep do
      alias Jido.Signal.ID

      defp build_signal_attrs(validated_data, opts) do
        caller = get_caller_module()

        attrs =
          build_base_attrs(validated_data, caller)
          |> maybe_add_datacontenttype()
          |> maybe_add_dataschema()
          |> apply_user_options(opts)

        {:ok, attrs}
      end

      defp build_base_attrs(validated_data, caller) do
        %{
          "data" => validated_data,
          "id" => ID.generate!(),
          "source" => @validated_opts[:default_source] || caller,
          "specversion" => "1.0.2",
          "time" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "type" => @validated_opts[:type]
        }
      end

      defp maybe_add_datacontenttype(attrs) do
        add_optional_attr(attrs, "datacontenttype", @validated_opts[:datacontenttype])
      end

      defp maybe_add_dataschema(attrs) do
        add_optional_attr(attrs, "dataschema", @validated_opts[:dataschema])
      end

      defp add_optional_attr(attrs, _key, nil), do: attrs
      defp add_optional_attr(attrs, key, value), do: Map.put(attrs, key, value)

      defp apply_user_options(attrs, opts) do
        Enum.reduce(opts, attrs, fn {key, value}, acc ->
          Map.put(acc, to_string(key), value)
        end)
      end
    end
  end

  @doc false
  defmacro define_caller_module_functions do
    quote location: :keep do
      defp get_caller_module do
        to_string(__MODULE__)
      end
    end
  end
end
