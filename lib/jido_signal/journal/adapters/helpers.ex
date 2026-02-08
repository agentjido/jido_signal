defmodule Jido.Signal.Journal.Adapters.Helpers do
  @moduledoc false

  alias Jido.Signal.ID
  alias Jido.Signal.Telemetry

  @spec build_dlq_entry(String.t(), term(), term(), map(), String.t() | nil) :: map()
  def build_dlq_entry(subscription_id, signal, reason, metadata, entry_id \\ nil) do
    %{
      id: entry_id || ID.generate!(),
      subscription_id: subscription_id,
      signal: signal,
      reason: reason,
      metadata: metadata,
      inserted_at: DateTime.utc_now()
    }
  end

  @spec emit_checkpoint_put(String.t()) :: :ok
  def emit_checkpoint_put(subscription_id) do
    Telemetry.execute(
      [:jido, :signal, :journal, :checkpoint, :put],
      %{},
      %{subscription_id: subscription_id}
    )
  end

  @spec emit_checkpoint_get(String.t(), boolean()) :: :ok
  def emit_checkpoint_get(subscription_id, found?) do
    Telemetry.execute(
      [:jido, :signal, :journal, :checkpoint, :get],
      %{},
      %{subscription_id: subscription_id, found: found?}
    )
  end

  @spec emit_dlq_put(String.t(), String.t()) :: :ok
  def emit_dlq_put(subscription_id, entry_id) do
    Telemetry.execute(
      [:jido, :signal, :journal, :dlq, :put],
      %{},
      %{subscription_id: subscription_id, entry_id: entry_id}
    )
  end

  @spec emit_dlq_get(String.t(), non_neg_integer()) :: :ok
  def emit_dlq_get(subscription_id, count) do
    Telemetry.execute(
      [:jido, :signal, :journal, :dlq, :get],
      %{count: count},
      %{subscription_id: subscription_id}
    )
  end
end
