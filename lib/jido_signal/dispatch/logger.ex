defmodule Jido.Signal.Dispatch.LoggerAdapter do
  @moduledoc """
  An adapter for dispatching signals through Elixir's Logger system.

  This adapter implements the `Jido.Signal.Dispatch.Adapter` behaviour and provides
  functionality to log signals using Elixir's built-in Logger. It supports both
  structured and unstructured logging formats and respects configured log levels.

  ## Configuration Options

  * `:level` - (optional) The log level to use, one of [:debug, :info, :warning, :error], defaults to `:info`
  * `:structured` - (optional) Whether to use structured logging format, defaults to `false`
  * `:data_mode` - (optional) `:raw` preserves legacy payload logging, `:preview` adds bounded safe-inspect previews

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
    data_preview: "...",
    source: "source"
  }
  ```

  ## Examples

      # Basic usage with default info level
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
  * High-volume signals can opt into `level: :debug`
  * Use `data_mode: :preview` to avoid dumping full payloads into logs
  """

  @behaviour Jido.Signal.Dispatch.Adapter

  require Logger

  @valid_levels [:debug, :info, :warning, :error]
  @valid_data_modes [:raw, :preview]
  @default_preview_limit :infinity
  @default_preview_max_length 200

  @impl Jido.Signal.Dispatch.Adapter
  @doc """
  Validates the logger adapter configuration options.

  ## Parameters

  * `opts` - Keyword list of options to validate

  ## Options

  * `:level` - (optional) One of #{inspect(@valid_levels)}, defaults to `:info`
  * `:structured` - (optional) Boolean, defaults to `false`
  * `:data_mode` - (optional) One of #{inspect(@valid_data_modes)}, defaults to `:raw`

  ## Returns

  * `{:ok, validated_opts}` - Options are valid
  * `{:error, reason}` - Options are invalid with string reason
  """
  @spec validate_opts(Keyword.t()) :: {:ok, Keyword.t()} | {:error, String.t()}
  def validate_opts(opts) do
    level = Keyword.get(opts, :level, :info)
    data_mode = Keyword.get(opts, :data_mode, :raw)

    cond do
      level not in @valid_levels ->
        {:error, "Invalid log level: #{inspect(level)}. Must be one of #{inspect(@valid_levels)}"}

      data_mode not in @valid_data_modes ->
        {:error,
         "Invalid data_mode: #{inspect(data_mode)}. Must be one of #{inspect(@valid_data_modes)}"}

      true ->
        {:ok, opts}
    end
  end

  @impl Jido.Signal.Dispatch.Adapter
  @doc """
  Logs a signal using the configured format and level.

  ## Parameters

  * `signal` - The signal to log
  * `opts` - Validated options from `validate_opts/1`

  ## Options

  * `:level` - (optional) The log level to use, defaults to `:info`
  * `:structured` - (optional) Whether to use structured format, defaults to `false`
  * `:data_mode` - (optional) `:raw` preserves legacy payload logging, `:preview` adds bounded previews

  ## Returns

  * `:ok` - Signal was logged successfully

  ## Examples

      iex> signal = %Jido.Signal{type: "user:created", data: %{id: 123}}
      iex> LoggerAdapter.deliver(signal, [level: :info])
      :ok
      # Logs: "Signal dispatched: user:created from source with data=%{id: 123}"

      iex> LoggerAdapter.deliver(signal, [level: :info, structured: true])
      :ok
      # Logs structured map with event details
  """
  @spec deliver(Jido.Signal.t(), Keyword.t()) :: :ok
  def deliver(signal, opts) do
    level = Keyword.get(opts, :level, :info)
    Logger.log(level, fn -> build_log_message(signal, opts) end, [])

    :ok
  end

  @doc false
  @spec build_log_message(Jido.Signal.t(), Keyword.t()) :: map() | String.t()
  def build_log_message(signal, opts \\ []) do
    if Keyword.get(opts, :structured, false) do
      message = %{
        event: "signal_dispatched",
        id: signal.id,
        type: signal.type,
        data: signal.data,
        source: signal.source
      }

      case Keyword.get(opts, :data_mode, :raw) do
        :preview ->
          Map.put(
            message,
            :data_preview,
            safe_inspect(signal.data,
              limit: @default_preview_limit,
              max_length: @default_preview_max_length
            )
          )

        :raw ->
          message
      end
    else
      payload =
        case Keyword.get(opts, :data_mode, :raw) do
          :preview ->
            safe_inspect(signal.data,
              limit: @default_preview_limit,
              max_length: @default_preview_max_length
            )

          :raw ->
            inspect(signal.data)
        end

      "SIGNAL: #{signal.type} from #{signal.source} with data=" <> payload
    end
  end

  defp safe_inspect(term, opts) do
    limit = Keyword.get(opts, :limit, 10)
    max_length = Keyword.get(opts, :max_length, @default_preview_max_length)

    inspected =
      try do
        inspect(term,
          limit: limit,
          printable_limit: max_length,
          width: max_length,
          charlists: :as_lists
        )
      rescue
        error -> "#inspect_error<#{Exception.message(error)}>"
      catch
        kind, _reason -> "#inspect_#{kind}<uninspectable>"
      end

    truncate(inspected, max_length)
  end

  defp truncate(binary, max_length) when is_binary(binary) do
    if String.length(binary) > max_length do
      String.slice(binary, 0, max_length) <> "..."
    else
      binary
    end
  end
end
