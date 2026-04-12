defmodule Jido.Signal.Telemetry do
  @moduledoc """
  Canonical telemetry helper for Jido Signal.

  This module centralizes trace-context metadata merging for telemetry emission
  and exposes a span helper for owning execution boundaries.
  """

  alias Jido.Signal.TraceContext

  @type event_name :: [atom()]

  @doc """
  Emits a telemetry event with package trace metadata merged in.
  """
  @spec execute(event_name(), map(), map()) :: :ok
  def execute(event_name, measurements, metadata \\ %{}) do
    :telemetry.execute(event_name, measurements, normalize_metadata(metadata))
  end

  @doc """
  Emits a telemetry span with package trace metadata merged in.

  The wrapped function should return `{result, stop_metadata}`.
  """
  @spec span(event_name(), map(), (-> {term(), map()})) :: term()
  def span(event_name, metadata, fun) when is_function(fun, 0) do
    :telemetry.span(event_name, normalize_metadata(metadata), fn ->
      {result, stop_metadata} = fun.()
      {result, normalize_metadata(stop_metadata)}
    end)
  end

  @spec attach(term(), event_name(), function(), map()) :: :ok | {:error, term()}
  def attach(handler_id, event_name, function, config) do
    :telemetry.attach(handler_id, event_name, function, config)
  end

  @spec detach(term()) :: :ok | {:error, term()}
  def detach(handler_id) do
    :telemetry.detach(handler_id)
  end

  defp normalize_metadata(metadata) do
    TraceContext.to_telemetry_metadata()
    |> Map.merge(metadata)
    |> drop_nil_entries()
  end

  defp drop_nil_entries(metadata) do
    Enum.reject(metadata, fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end
end
