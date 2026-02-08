defmodule Jido.Signal.Bus.DispatchPipeline do
  @moduledoc false

  alias Jido.Signal.Bus.MiddlewarePipeline
  alias Jido.Signal.Config
  alias Jido.Signal.Dispatch
  alias Jido.Signal.Telemetry

  require Logger

  @type extra_metadata :: map()
  @type telemetry_opts :: %{required(:bus_name) => atom(), optional(:extra_metadata) => map()}
  @type middleware_config :: {module(), term()}
  @type dispatch_result :: :ok | {:error, term()}
  @type dispatch_with_middleware_result ::
          {:dispatch, [middleware_config()], dispatch_result()}
          | {:skip, [middleware_config()]}
          | {:middleware_error, [middleware_config()], term()}

  @spec emit_before_dispatch(atom(), Jido.Signal.t(), String.t(), map(), extra_metadata()) :: :ok
  def emit_before_dispatch(bus_name, signal, subscription_id, subscription, extra_metadata \\ %{}) do
    Telemetry.execute(
      [:jido, :signal, :bus, :before_dispatch],
      %{timestamp: System.monotonic_time(:microsecond)},
      base_metadata(bus_name, signal, subscription_id, subscription)
      |> Map.merge(extra_metadata)
    )
  end

  @spec emit_after_dispatch(atom(), Jido.Signal.t(), String.t(), map(), term(), extra_metadata()) ::
          :ok
  def emit_after_dispatch(
        bus_name,
        signal,
        subscription_id,
        subscription,
        result,
        extra_metadata \\ %{}
      ) do
    Telemetry.execute(
      [:jido, :signal, :bus, :after_dispatch],
      %{timestamp: System.monotonic_time(:microsecond)},
      base_metadata(bus_name, signal, subscription_id, subscription)
      |> Map.put(:dispatch_result, result)
      |> Map.merge(extra_metadata)
    )
  end

  @spec emit_dispatch_skipped(
          atom(),
          Jido.Signal.t(),
          String.t(),
          map(),
          term(),
          extra_metadata()
        ) ::
          :ok
  def emit_dispatch_skipped(
        bus_name,
        signal,
        subscription_id,
        subscription,
        reason,
        extra_metadata \\ %{}
      ) do
    Telemetry.execute(
      [:jido, :signal, :bus, :dispatch_skipped],
      %{timestamp: System.monotonic_time(:microsecond)},
      base_metadata(bus_name, signal, subscription_id, subscription)
      |> Map.put(:reason, reason)
      |> Map.merge(extra_metadata)
    )
  end

  @spec emit_dispatch_error(atom(), Jido.Signal.t(), String.t(), map(), term(), extra_metadata()) ::
          :ok
  def emit_dispatch_error(
        bus_name,
        signal,
        subscription_id,
        subscription,
        error,
        extra_metadata \\ %{}
      ) do
    Telemetry.execute(
      [:jido, :signal, :bus, :dispatch_error],
      %{timestamp: System.monotonic_time(:microsecond)},
      base_metadata(bus_name, signal, subscription_id, subscription)
      |> Map.put(:error, error)
      |> Map.merge(extra_metadata)
    )
  end

  @spec dispatch_async(Jido.Signal.t(), map(), keyword()) :: :ok | {:error, term()}
  def dispatch_async(signal, subscription, dispatch_opts) do
    case Dispatch.dispatch_async(signal, subscription.dispatch, dispatch_opts) do
      {:ok, _task} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec dispatch_with_middleware(
          [middleware_config()],
          Jido.Signal.t(),
          String.t(),
          map(),
          map(),
          pos_integer(),
          (Jido.Signal.t(), map() -> dispatch_result()),
          telemetry_opts()
        ) :: dispatch_with_middleware_result()
  def dispatch_with_middleware(
        middleware,
        signal,
        subscription_id,
        subscription,
        context,
        timeout_ms,
        dispatch_fun,
        telemetry_opts
      )
      when is_function(dispatch_fun, 2) do
    bus_name = Map.fetch!(telemetry_opts, :bus_name)
    extra_metadata = Map.get(telemetry_opts, :extra_metadata, %{})

    emit_before_dispatch(bus_name, signal, subscription_id, subscription, extra_metadata)

    middleware_result =
      MiddlewarePipeline.before_dispatch(
        middleware,
        signal,
        subscription,
        context,
        timeout_ms
      )

    case middleware_result do
      {:ok, processed_signal, updated_middleware} ->
        result = dispatch_fun.(processed_signal, subscription)

        emit_after_dispatch(
          bus_name,
          processed_signal,
          subscription_id,
          subscription,
          result,
          extra_metadata
        )

        next_middleware =
          MiddlewarePipeline.after_dispatch(
            updated_middleware,
            processed_signal,
            subscription,
            result,
            context,
            timeout_ms
          )

        {:dispatch, next_middleware, result}

      :skip ->
        emit_dispatch_skipped(
          bus_name,
          signal,
          subscription_id,
          subscription,
          :middleware_skip,
          extra_metadata
        )

        {:skip, middleware}

      {:error, reason} ->
        emit_dispatch_error(
          bus_name,
          signal,
          subscription_id,
          subscription,
          reason,
          extra_metadata
        )

        Logger.warning("Middleware halted dispatch for signal #{signal.id}: #{inspect(reason)}")

        {:middleware_error, middleware, reason}
    end
  end

  defp base_metadata(bus_name, signal, subscription_id, subscription) do
    base = %{
      bus_name: bus_name,
      signal_id: signal.id,
      signal_type: signal.type,
      subscription_id: subscription_id,
      subscription_path: subscription.path
    }

    if Config.get_env(:telemetry_include_payload, false) do
      Map.merge(base, %{signal: signal, subscription: subscription})
    else
      base
    end
  end
end
