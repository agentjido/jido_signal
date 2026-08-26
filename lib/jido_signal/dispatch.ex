defmodule Jido.Signal.Dispatch do
  @moduledoc """
  Validates dispatch targets and delivers Signals.

  Dispatch is synchronous. A target is an `{adapter, options}` tuple. A list of
  targets is delivered in registration order. The caller owns asynchronous work,
  retries, concurrency limits, and circuit breaking.

  Built-in adapters are `:pid`, `:named`, `:pubsub`, `:bus`, `:logger`,
  `:console`, `:noop`, and `:http`. A custom adapter can implement
  `Jido.Signal.Dispatch.Adapter`.
  """

  alias Jido.Signal.Dispatch.Target
  alias Jido.Signal.Error
  alias Jido.Signal.Telemetry

  @type adapter ::
          :pid
          | :bus
          | :named
          | :pubsub
          | :logger
          | :console
          | :noop
          | :http
          | nil
          | module()
  @type dispatch_config :: {adapter(), keyword()}
  @type dispatch_configs :: dispatch_config() | [dispatch_config()]

  @normalize_errors_compile_time Application.compile_env(
                                   :jido,
                                   :normalize_dispatch_errors,
                                   false
                                 )

  @builtin_adapters %{
    pid: Jido.Signal.Dispatch.PidAdapter,
    named: Jido.Signal.Dispatch.Named,
    pubsub: Jido.Signal.Dispatch.PubSub,
    bus: Jido.Signal.Dispatch.Bus,
    logger: Jido.Signal.Dispatch.LoggerAdapter,
    console: Jido.Signal.Dispatch.ConsoleAdapter,
    noop: Jido.Signal.Dispatch.NoopAdapter,
    http: Jido.Signal.Dispatch.Http
  }

  @doc """
  Validates one target tuple or a list of target tuples.

  The return value keeps the public tuple form. Dispatch uses an internal Target
  value after this boundary.
  """
  @spec validate_opts(dispatch_configs()) :: {:ok, dispatch_configs()} | {:error, term()}
  def validate_opts({adapter, opts}) when is_atom(adapter) and is_list(opts) do
    with {:ok, target} <- normalize_target({adapter, opts}) do
      {:ok, Target.to_tuple(target)}
    end
  end

  def validate_opts(configs) when is_list(configs) do
    configs
    |> Enum.reduce_while({:ok, []}, fn config, {:ok, targets} ->
      case normalize_target(config) do
        {:ok, target} -> {:cont, {:ok, [Target.to_tuple(target) | targets]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, targets} -> {:ok, Enum.reverse(targets)}
      error -> error
    end
  end

  def validate_opts(invalid_config), do: invalid_dispatch_config(invalid_config)

  @doc """
  Delivers a Signal to one target or a list of targets.

  A single target returns `:ok` or `{:error, reason}`. A target list returns
  `:ok` or `{:error, reasons}`. List delivery is synchronous and ordered.
  """
  @spec dispatch(Jido.Signal.t(), dispatch_configs()) :: :ok | {:error, term()}
  def dispatch(signal, {adapter, opts} = config) when is_atom(adapter) and is_list(opts) do
    with {:ok, target} <- normalize_target(config) do
      deliver(signal, target)
    end
  end

  def dispatch(signal, configs) when is_list(configs) do
    errors =
      Enum.reduce(configs, [], fn config, errors ->
        result =
          with {:ok, target} <- normalize_target(config) do
            deliver(signal, target)
          end

        case result do
          :ok -> errors
          {:error, reason} -> [reason | errors]
        end
      end)

    case Enum.reverse(errors) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  def dispatch(_signal, invalid_config), do: invalid_dispatch_config(invalid_config)

  defp normalize_target({nil, opts}) when is_list(opts) do
    Target.new(nil, nil, strip_internal_opts(opts))
  end

  defp normalize_target({adapter, opts} = config) when is_atom(adapter) and is_list(opts) do
    opts = strip_internal_opts(opts)

    with {:ok, adapter_module} <- resolve_adapter(adapter),
         {:ok, validated_opts} <- adapter_module.validate_opts(opts),
         {:ok, target} <- Target.new(adapter, adapter_module, validated_opts) do
      {:ok, target}
    else
      {:error, reason} -> normalize_validation_error(reason, adapter, config)
    end
  end

  defp normalize_target(invalid_config), do: invalid_dispatch_config(invalid_config)

  defp deliver(_signal, %Target{adapter: nil}), do: :ok

  defp deliver(signal, %Target{} = target) do
    with_dispatch_telemetry(signal, target, fn ->
      case target.module.deliver(signal, target.opts) do
        :ok -> :ok
        {:error, reason} -> normalize_error(reason, target.adapter, Target.to_tuple(target))
      end
    end)
  end

  defp with_dispatch_telemetry(signal, target, fun) do
    start_time = System.monotonic_time(:millisecond)
    metadata = dispatch_telemetry_metadata(signal, target)
    Telemetry.execute([:jido, :dispatch, :start], %{}, metadata, signal)

    result =
      try do
        fun.()
      catch
        kind, reason ->
          Telemetry.execute(
            [:jido, :dispatch, :exception],
            dispatch_latency(start_time),
            Map.merge(metadata, %{
              outcome: :raised,
              success?: false,
              error_type: :dispatch_error,
              retryable?: false,
              exception_kind: kind,
              exception_module: exception_module(reason)
            }),
            signal
          )

          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    measurements = dispatch_latency(start_time)

    case result do
      :ok ->
        Telemetry.execute(
          [:jido, :dispatch, :stop],
          measurements,
          Map.merge(metadata, %{outcome: :ok, success?: true}),
          signal
        )

      {:error, reason} ->
        error = dispatch_error_for_telemetry(reason, target)

        Telemetry.execute(
          [:jido, :dispatch, :exception],
          measurements,
          Map.merge(metadata, %{
            outcome: :error,
            success?: false,
            error_type: Error.type(error),
            retryable?: Error.retryable?(error)
          }),
          signal
        )
    end

    result
  end

  defp dispatch_latency(start_time) do
    %{latency_ms: System.monotonic_time(:millisecond) - start_time}
  end

  defp exception_module(%{__exception__: true, __struct__: module}) when is_atom(module),
    do: module

  defp exception_module(_reason), do: :unknown

  defp dispatch_telemetry_metadata(signal, target) do
    %{
      adapter: target.adapter,
      runtime_surface: :dispatch,
      signal_type: signal_type(signal),
      target: get_target_from_opts(target.opts),
      target_kind: target_kind(target.opts)
    }
  end

  defp signal_type(%{type: type}) when is_binary(type), do: type
  defp signal_type(_signal), do: :unknown

  defp get_target_from_opts(opts) do
    cond do
      target = Keyword.get(opts, :target) -> target
      url = Keyword.get(opts, :url) -> url_target_for_telemetry(url)
      pid = Keyword.get(opts, :pid) -> pid
      name = Keyword.get(opts, :name) -> name
      topic = Keyword.get(opts, :topic) -> topic
      true -> :unknown
    end
  end

  defp url_target_for_telemetry(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        uri
        |> Map.put(:userinfo, nil)
        |> Map.put(:query, nil)
        |> Map.put(:fragment, nil)
        |> URI.to_string()

      _ ->
        :invalid_url
    end
  end

  defp url_target_for_telemetry(_url), do: :invalid_url

  defp target_kind(opts) do
    cond do
      Keyword.has_key?(opts, :url) -> :url
      Keyword.has_key?(opts, :topic) -> :topic
      Keyword.has_key?(opts, :pid) -> :pid
      match?({:name, _}, Keyword.get(opts, :target)) -> :name
      is_pid(Keyword.get(opts, :target)) -> :pid
      Keyword.has_key?(opts, :target) -> :target
      true -> :unknown
    end
  end

  defp resolve_adapter(nil), do: {:ok, nil}

  defp resolve_adapter(adapter) when is_atom(adapter) do
    case Map.fetch(@builtin_adapters, adapter) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        if dispatch_adapter_module?(adapter) do
          {:ok, adapter}
        else
          {:error, invalid_adapter_message(adapter)}
        end
    end
  end

  defp dispatch_adapter_module?(adapter) do
    Code.ensure_loaded?(adapter) and
      function_exported?(adapter, :validate_opts, 1) and
      function_exported?(adapter, :deliver, 2) and
      Jido.Signal.Dispatch.Adapter in (adapter.module_info(:attributes)[:behaviour] || [])
  rescue
    _ -> false
  end

  defp invalid_adapter_message(adapter) do
    "#{inspect(adapter)} is not a valid adapter - must be one of :pid, :named, " <>
      ":pubsub, :bus, :logger, :console, :noop, :http or a module " <>
      "implementing Jido.Signal.Dispatch.Adapter"
  end

  defp strip_internal_opts(opts), do: Keyword.delete(opts, :__validated__)

  defp invalid_dispatch_config(invalid_config) do
    if should_normalize_errors?() do
      {:error,
       Error.validation_error("Invalid dispatch configuration", %{
         field: "dispatch_config",
         value: dispatch_config_shape(invalid_config),
         reason: :invalid_dispatch_config
       })}
    else
      {:error, :invalid_dispatch_config}
    end
  end

  defp dispatch_config_shape(value) when is_map(value),
    do: %{type: :map, size: map_size(value)}

  defp dispatch_config_shape(value) when is_list(value),
    do: %{type: :list, count: length(value)}

  defp dispatch_config_shape(value) when is_tuple(value),
    do: %{type: :tuple, size: tuple_size(value)}

  defp dispatch_config_shape(value) when is_binary(value),
    do: %{type: :binary, bytes: byte_size(value)}

  defp dispatch_config_shape(value) when is_atom(value), do: %{type: :atom}
  defp dispatch_config_shape(value) when is_number(value), do: %{type: :number}
  defp dispatch_config_shape(_value), do: %{type: :other}

  defp normalize_error(reason, adapter, config) do
    if should_normalize_errors?() do
      {:error,
       Error.dispatch_error("Signal dispatch failed", %{
         adapter: adapter,
         reason: reason,
         target: target_summary(adapter, config)
       })}
    else
      {:error, reason}
    end
  end

  defp normalize_validation_error(reason, adapter, config) do
    if should_normalize_errors?() do
      {:error,
       Error.validation_error("Invalid adapter configuration", %{
         field: "config",
         adapter: adapter,
         reason: reason,
         target: target_summary(adapter, config)
       })}
    else
      {:error, reason}
    end
  end

  defp should_normalize_errors? do
    Application.get_env(
      :jido_signal,
      :normalize_dispatch_errors,
      Application.get_env(:jido, :normalize_dispatch_errors, @normalize_errors_compile_time)
    )
  end

  defp dispatch_error_for_telemetry(%Error.DispatchError{} = error, _target), do: error

  defp dispatch_error_for_telemetry(reason, target) do
    Error.dispatch_error("Signal dispatch failed", %{
      adapter: target.adapter,
      reason: reason,
      target: target_summary(target.adapter, Target.to_tuple(target))
    })
  end

  defp target_summary(adapter, {_configured_adapter, opts}) when is_list(opts) do
    %{
      adapter: adapter,
      target: get_target_from_opts(opts),
      target_kind: target_kind(opts)
    }
  end

  defp target_summary(adapter, _config), do: %{adapter: adapter}
end
