defmodule Jido.Signal.Dispatch.LoggerAdapter do
  @moduledoc """
  An adapter for dispatching signals through Elixir's Logger system.

  This adapter implements the `Jido.Signal.Dispatch.Adapter` behaviour and provides
  functionality to log signals using Elixir's built-in Logger. It supports both
  structured and unstructured logging formats and respects configured log levels.

  ## Configuration Options

  * `:level` - (optional) The log level to use, one of [:debug, :info, :warning, :error], defaults to `:info`
  * `:structured` - (optional) Whether to use structured logging format, defaults to `false`

  ## Logging Formats

  ### Unstructured (default)
  ```
  Signal dispatched: signal_type from source with data={...}
  ```

  ### Structured
  ```elixir
  %{
    event: "signal_dispatched",
    id: "signal_id",
    type: "signal_type",
    data: {...},
    source: "source"
  }
  ```

  ## Examples

      # Basic usage with default level
      config = {:logger, []}

      # Custom log level
      config = {:logger, [
        level: :debug
      ]}

      # Structured logging
      config = {:logger, [
        level: :info,
        structured: true
      ]}

  ## Integration with Logger

  The adapter integrates with Elixir's Logger system, which means:
  * Log messages respect the global Logger configuration
  * Metadata and formatting can be customized through Logger backends
  * Log levels can be filtered at runtime
  * Structured logging can be processed by log aggregators

  ## Notes

  * Consider using structured logging when integrating with log aggregation systems
  * Log levels should be chosen based on the signal's importance
  * High-volume signals should use `:debug` level to avoid log spam
  """

  @behaviour Jido.Signal.Dispatch.Adapter

  alias Jido.Signal.Sanitizer

  require Logger

  @valid_levels [:debug, :info, :warning, :error]
  @options_schema Zoi.keyword(
                    [
                      level: Zoi.enum(@valid_levels) |> Zoi.optional(),
                      log_level: Zoi.enum(@valid_levels) |> Zoi.optional(),
                      structured: Zoi.boolean() |> Zoi.optional(),
                      include_data: Zoi.boolean() |> Zoi.optional()
                    ],
                    unrecognized_keys: :error
                  )

  @impl Jido.Signal.Dispatch.Adapter
  def options_schema, do: @options_schema

  @impl Jido.Signal.Dispatch.Adapter
  @doc """
  Logs a signal using the configured format and level.
  """
  @spec deliver(Jido.Signal.t(), Keyword.t()) :: :ok
  def deliver(signal, opts) do
    level = resolve_log_level(opts)
    structured = Keyword.get(opts, :structured, false)
    include_data = Keyword.get(opts, :include_data, true)

    Logger.log(
      level,
      fn ->
        if structured do
          structured_payload(signal, include_data)
        else
          build_log_message(signal, include_data)
        end
      end,
      []
    )

    :ok
  end

  defp structured_payload(signal, include_data) do
    payload = %{
      event: "signal_dispatched",
      id: signal.id,
      type: signal.type,
      source: signal.source
    }

    if include_data do
      Map.put(payload, :data, Sanitizer.sanitize(signal.data, :telemetry))
    else
      payload
    end
  end

  defp build_log_message(signal, false) do
    "SIGNAL: #{signal.type} from #{signal.source}"
  end

  defp build_log_message(signal, true) do
    "SIGNAL: #{signal.type} from #{signal.source} " <>
      "with data=#{Sanitizer.preview(signal.data, :telemetry)}"
  end

  defp resolve_log_level(opts) do
    default =
      :jido_signal
      |> Application.get_env(:default_log_level, :info)
      |> normalize_log_level(:info)

    opts
    |> Keyword.get(:log_level, Keyword.get(opts, :level, default))
    |> normalize_log_level(default)
  end

  defp normalize_log_level(level, _fallback) when level in @valid_levels, do: level
  defp normalize_log_level(_level, fallback), do: fallback
end
