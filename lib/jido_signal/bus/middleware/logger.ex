defmodule Jido.Signal.Bus.Middleware.Logger do
  @moduledoc """
  A middleware that logs signal activity using Elixir's Logger.

  This middleware provides comprehensive logging of signal flows through the bus,
  including publishing events, dispatch events, and errors. It's useful for
  debugging, monitoring, and auditing signal activity.

  ## Configuration Options

  - `:level` - Log level to use (default: `:info`)
  - `:log_publish` - Whether to log publish events (default: `true`)
  - `:log_dispatch` - Whether to log dispatch events (default: `true`)
  - `:log_errors` - Whether to log errors (default: `true`)
  - `:include_signal_data` - Whether to include signal data in logs (default: `false`)
  - `:max_data_length` - Maximum length of signal data to log (default: `100`)

  ## Examples

      # Basic logging at info level
      middleware = [{Jido.Signal.Bus.Middleware.Logger, []}]

      # Debug level with signal data
      middleware = [
        {Jido.Signal.Bus.Middleware.Logger, [
          level: :debug,
          include_signal_data: true,
          max_data_length: 200
        ]}
      ]

      # Only log errors
      middleware = [
        {Jido.Signal.Bus.Middleware.Logger, [
          log_publish: false,
          log_dispatch: false,
          log_errors: true
        ]}
      ]
  """

  use Jido.Signal.Bus.Middleware

  alias Jido.Signal.Sanitizer
  alias Jido.Signal.Util

  require Logger

  @type context :: Jido.Signal.Bus.Middleware.context()
  @type dispatch_result :: Jido.Signal.Bus.Middleware.dispatch_result()

  @impl true
  def init(opts) do
    config = %{
      level: Util.resolve_log_level(opts),
      log_publish: Keyword.get(opts, :log_publish, true),
      log_dispatch: Keyword.get(opts, :log_dispatch, true),
      log_errors: Keyword.get(opts, :log_errors, true),
      include_signal_data: Keyword.get(opts, :include_signal_data, false),
      max_data_length: Keyword.get(opts, :max_data_length, 100)
    }

    {:ok, config}
  end

  @impl true
  def before_publish(signals, context, config) do
    if config.log_publish do
      log_publish_summary(signals, context, config)
      maybe_log_signal_data(signals, config)
    end

    {:cont, signals, config}
  end

  defp log_publish_summary(signals, context, config) do
    signal_count = length(signals)
    signal_types = signals |> Enum.map(& &1.type) |> Enum.uniq()

    Logger.log(
      config.level,
      fn ->
        "Bus #{context.bus_name}: publishing #{signal_count} signal(s) types=#{inspect(signal_types)}"
      end,
      bus_name: context.bus_name,
      signal_count: signal_count
    )
  end

  defp maybe_log_signal_data(signals, config) do
    if config.include_signal_data do
      Enum.each(signals, fn signal ->
        log_single_signal_data(signal, config)
      end)
    end
  end

  defp log_single_signal_data(signal, config) do
    Logger.log(
      config.level,
      fn ->
        "signal payload id=#{signal.id} type=#{signal.type} source=#{signal.source} " <>
          "data=#{format_signal_data(signal.data, config.max_data_length)}"
      end,
      signal_id: signal.id,
      signal_type: signal.type
    )
  end

  @impl true
  def after_publish(signals, context, config) do
    if config.log_publish do
      signal_count = length(signals)

      Logger.log(
        config.level,
        fn ->
          "Bus #{context.bus_name}: published #{signal_count} signal(s)"
        end,
        bus_name: context.bus_name,
        signal_count: signal_count
      )
    end

    {:cont, signals, config}
  end

  @impl true
  def before_dispatch(signal, subscriber, context, config) do
    if config.log_dispatch do
      dispatch_info = format_dispatch_info(subscriber.dispatch)

      Logger.log(
        config.level,
        fn ->
          "Bus #{context.bus_name}: dispatching signal id=#{signal.id} type=#{signal.type} " <>
            "subscription=#{subscriber.id} path=#{subscriber.path} dispatch=#{dispatch_info}"
        end,
        bus_name: context.bus_name,
        signal_id: signal.id,
        signal_type: signal.type,
        subscription_id: subscriber.id
      )
    end

    {:cont, signal, config}
  end

  @impl true
  def after_dispatch(signal, subscriber, result, context, config) do
    case result do
      :ok -> maybe_log_dispatch_success(signal, subscriber, context, config)
      {:error, reason} -> maybe_log_dispatch_error(signal, subscriber, reason, context, config)
    end

    {:cont, config}
  end

  # Private helper functions

  defp maybe_log_dispatch_success(_signal, _subscriber, _context, %{log_dispatch: false}), do: :ok

  defp maybe_log_dispatch_success(signal, subscriber, context, config) do
    dispatch_info = format_dispatch_info(subscriber.dispatch)

    Logger.log(
      config.level,
      fn ->
        "Bus #{context.bus_name}: dispatched signal id=#{signal.id} type=#{signal.type} " <>
          "subscription=#{subscriber.id} path=#{subscriber.path} dispatch=#{dispatch_info}"
      end,
      bus_name: context.bus_name,
      signal_id: signal.id,
      signal_type: signal.type,
      subscription_id: subscriber.id
    )
  end

  defp maybe_log_dispatch_error(_signal, _subscriber, _reason, _context, %{log_errors: false}),
    do: :ok

  defp maybe_log_dispatch_error(signal, subscriber, reason, context, config) do
    dispatch_info = format_dispatch_info(subscriber.dispatch)

    Logger.error(
      fn ->
        "Bus #{context.bus_name}: failed dispatch signal id=#{signal.id} type=#{signal.type} " <>
          "subscription=#{subscriber.id} path=#{subscriber.path} dispatch=#{dispatch_info} " <>
          "reason=#{Sanitizer.preview(reason, :telemetry, max_length: config.max_data_length)}"
      end,
      bus_name: context.bus_name,
      signal_id: signal.id,
      signal_type: signal.type,
      subscription_id: subscriber.id
    )
  end

  defp format_signal_data(nil, _max_length), do: "nil"

  defp format_signal_data(data, max_length) when is_binary(data) do
    Sanitizer.preview(data, :telemetry, max_length: max_length)
  end

  defp format_signal_data(data, max_length) do
    Sanitizer.preview(data, :telemetry, max_length: max_length)
  end

  defp format_dispatch_info({:pid, opts}) do
    target = Keyword.get(opts, :target, "unknown")
    mode = Keyword.get(opts, :delivery_mode, :async)
    "pid(#{inspect(target)}, #{mode})"
  end

  defp format_dispatch_info({:function, {module, function}}) do
    "function(#{module}.#{function})"
  end

  defp format_dispatch_info({:function, {module, function, args}}) do
    "function(#{module}.#{function}/#{length(args)})"
  end

  defp format_dispatch_info(dispatch) do
    inspect(dispatch)
  end
end
