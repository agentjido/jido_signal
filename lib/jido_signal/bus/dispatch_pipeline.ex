defmodule Jido.Signal.Bus.DispatchPipeline do
  @moduledoc false

  alias Jido.Signal.Dispatch
  alias Jido.Signal.Telemetry

  @type extra_metadata :: map()

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

  defp base_metadata(bus_name, signal, subscription_id, subscription) do
    %{
      bus_name: bus_name,
      signal_id: signal.id,
      signal_type: signal.type,
      subscription_id: subscription_id,
      subscription_path: subscription.path,
      signal: signal,
      subscription: subscription
    }
  end
end
