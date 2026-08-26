defmodule Jido.Signal.Telemetry do
  @moduledoc """
  Canonical telemetry helper for Jido Signal.

  Callers add Signal trace metadata explicitly with `add_trace/2`.
  """

  alias Jido.Signal
  alias Jido.Signal.Trace

  @type event_name :: [atom()]

  @doc """
  Emits a telemetry event.
  """
  @spec execute(event_name(), map(), map()) :: :ok
  def execute(event_name, measurements, metadata \\ %{}) do
    :telemetry.execute(event_name, measurements, drop_nil_entries(metadata))
  end

  @doc "Adds trace IDs and flags from a Signal to telemetry metadata."
  @spec add_trace(map(), Signal.t()) :: map()
  def add_trace(metadata, %Signal{} = signal) when is_map(metadata) do
    case Trace.get(signal) do
      %Trace{} = trace ->
        Map.merge(
          %{
            jido_trace_id: trace.trace_id,
            jido_span_id: trace.span_id,
            jido_trace_flags: trace.trace_flags
          },
          metadata
        )

      nil ->
        metadata
    end
  end

  def add_trace(metadata, _signal) when is_map(metadata), do: metadata

  @spec attach(term(), event_name(), function(), map()) :: :ok | {:error, term()}
  def attach(handler_id, event_name, function, config) do
    :telemetry.attach(handler_id, event_name, function, config)
  end

  @spec detach(term()) :: :ok | {:error, term()}
  def detach(handler_id) do
    :telemetry.detach(handler_id)
  end

  defp drop_nil_entries(metadata) do
    Enum.reject(metadata, fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end
end
