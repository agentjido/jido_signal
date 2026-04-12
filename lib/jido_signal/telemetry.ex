defmodule Jido.Signal.Telemetry do
  @moduledoc """
  Canonical telemetry helper for Jido Signal.

  This module centralizes metadata shaping for telemetry emission and exposes a
  span helper for owning execution boundaries.
  """

  alias Jido.Signal.Sanitizer
  alias Jido.Signal.TraceContext

  @type event_name :: [atom()]

  @doc """
  Emits a telemetry event with bounded metadata.
  """
  @spec execute(event_name(), map(), map()) :: :ok
  def execute(event_name, measurements, metadata \\ %{}) do
    :telemetry.execute(
      event_name,
      normalize_measurements(measurements),
      normalize_metadata(metadata)
    )
  end

  @doc """
  Emits a telemetry span with bounded metadata.

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

  defp normalize_measurements(measurements) do
    Map.new(measurements, fn
      {key, value} when is_integer(value) or is_float(value) ->
        {key, value}

      {key, value} ->
        {key, Sanitizer.sanitize(value, :telemetry)}
    end)
  end

  defp normalize_metadata(metadata) do
    TraceContext.to_telemetry_metadata()
    |> Map.merge(metadata)
    |> Sanitizer.sanitize(:telemetry)
  end
end
