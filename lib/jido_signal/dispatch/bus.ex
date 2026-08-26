defmodule Jido.Signal.Dispatch.Bus do
  @moduledoc """
  An adapter for dispatching signals through the Jido signal bus system.

  This adapter implements the `Jido.Signal.Dispatch.Adapter` behaviour and provides
  functionality to publish signals to named signal buses. It integrates with the
  `Jido.Signal.Bus` system for signal distribution.

  ## Configuration Options

  * `:target` - (required) The atom name of the target bus
  * `:jido` - (optional) The instance module for instance-scoped bus lookup

  ## Signal Bus Integration

  The adapter uses `Jido.Signal.Bus` to:
  * Locate the target bus process using `Jido.Signal.Bus.whereis/2`
  * Publish signals using `Jido.Signal.Bus.publish/2`

  ## Examples

      # Basic usage
      config = {:bus, [
        target: :my_bus
      ]}

      # Instance-scoped bus lookup
      config = {:bus, [
        target: :my_bus,
        jido: MyApp.Jido
      ]}

  ## Error Handling

  The adapter handles these error conditions:

  * `:bus_not_found` - The target bus is not registered
  * Other errors from the bus system
  """

  @behaviour Jido.Signal.Dispatch.Adapter

  alias Jido.Signal.Bus
  alias Jido.Signal.Dispatch.Adapter
  alias Jido.Signal.Sanitizer

  @options_schema Zoi.keyword(
                    target:
                      Zoi.atom()
                      |> Zoi.refine({__MODULE__, :not_nil?, []})
                      |> Zoi.required(),
                    jido: Zoi.atom() |> Zoi.nullable() |> Zoi.optional()
                  )

  require Logger

  @type delivery_target :: atom()
  @type delivery_opts :: [
          target: delivery_target(),
          jido: module() | nil
        ]
  @type delivery_error ::
          :bus_not_found
          | term()

  @impl Jido.Signal.Dispatch.Adapter
  @doc """
  Validates the bus adapter configuration options.

  ## Parameters

  * `opts` - Keyword list of options to validate

  ## Options

  * `:target` - Must be an atom representing the bus name
  * `:jido` - Must be an atom representing the instance module, or nil

  ## Returns

  * `{:ok, validated_opts}` - Options are valid
  * `{:error, reason}` - Options are invalid with string reason
  """
  @spec validate_opts(Keyword.t()) :: {:ok, Keyword.t()} | {:error, term()}
  def validate_opts(opts), do: Adapter.validate(@options_schema, opts)

  @impl Jido.Signal.Dispatch.Adapter
  def options_schema, do: @options_schema

  @doc false
  def not_nil?(nil, _opts), do: {:error, "must not be nil"}
  def not_nil?(_value, _opts), do: :ok

  @impl Jido.Signal.Dispatch.Adapter
  @doc """
  Delivers a signal to the specified signal bus.

  ## Parameters

  * `signal` - The signal to deliver
  * `opts` - Validated options from `validate_opts/1`

  ## Options

  * `:target` - (required) The atom name of the target bus
  * `:jido` - (optional) The instance module for scoped lookup

  ## Returns

  * `:ok` - Signal published successfully
  * `{:error, :bus_not_found}` - Target bus not found
  * `{:error, reason}` - Other delivery failure
  """
  @spec deliver(Jido.Signal.t(), delivery_opts()) ::
          :ok | {:error, delivery_error()}
  def deliver(signal, opts) do
    bus_name = Keyword.fetch!(opts, :target)
    jido = Keyword.get(opts, :jido)

    lookup_opts = if jido, do: [jido: jido], else: []

    try do
      case Bus.whereis(bus_name, lookup_opts) do
        {:ok, pid} ->
          case Bus.publish(pid, [signal]) do
            {:ok, _recorded} -> :ok
            {:error, reason} -> {:error, reason}
          end

        {:error, :not_found} ->
          Logger.error(fn -> "Dispatch bus target not found bus_name=#{bus_name}" end)
          {:error, :bus_not_found}
      end
    rescue
      ArgumentError ->
        Logger.error(fn ->
          "Dispatch bus target lookup failed bus_name=#{Sanitizer.preview(bus_name, :telemetry)}"
        end)

        {:error, :bus_not_found}
    end
  end
end
