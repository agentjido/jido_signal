defmodule Jido.Signal.Journal.Adapters.InMemory do
  @moduledoc """
  In-memory implementation of the Journal persistence behavior.
  Uses Agent to maintain state.
  """
  @behaviour Jido.Signal.Journal.Persistence

  use Agent

  alias Jido.Signal.Journal.Adapters.Helpers

  @impl true
  def init do
    case Agent.start_link(fn ->
           %{
             signals: %{},
             causes: %{},
             effects: %{},
             conversations: %{},
             checkpoints: %{},
             dlq: %{}
           }
         end) do
      {:ok, pid} -> {:ok, pid}
      error -> error
    end
  end

  @impl true
  def put_signal(signal, pid \\ nil) do
    target = pid || __MODULE__

    Agent.update(target, fn state ->
      put_in(state, [:signals, signal.id], signal)
    end)
  end

  @impl true
  def get_signal(signal_id, pid \\ nil) do
    target = pid || __MODULE__

    case Agent.get(target, fn state -> get_in(state, [:signals, signal_id]) end) do
      nil -> {:error, :not_found}
      signal -> {:ok, signal}
    end
  end

  @impl true
  def put_cause(cause_id, effect_id, pid \\ nil) do
    target = pid || __MODULE__

    Agent.update(target, fn state ->
      state
      |> update_in([:causes, cause_id], &MapSet.put(&1 || MapSet.new(), effect_id))
      |> update_in([:effects, effect_id], &MapSet.put(&1 || MapSet.new(), cause_id))
    end)
  end

  @impl true
  def get_effects(signal_id, pid \\ nil) do
    target = pid || __MODULE__
    {:ok, Agent.get(target, fn state -> get_in(state, [:causes, signal_id]) || MapSet.new() end)}
  end

  @impl true
  def get_cause(signal_id, pid \\ nil) do
    target = pid || __MODULE__

    case Agent.get(target, fn state -> get_in(state, [:effects, signal_id]) end) do
      nil -> {:error, :not_found}
      effects -> {:ok, MapSet.to_list(effects) |> List.first()}
    end
  end

  @impl true
  def put_conversation(conversation_id, signal_id, pid \\ nil) do
    target = pid || __MODULE__

    Agent.update(target, fn state ->
      update_in(
        state,
        [:conversations, conversation_id],
        &MapSet.put(&1 || MapSet.new(), signal_id)
      )
    end)
  end

  @impl true
  def get_conversation(conversation_id, pid \\ nil) do
    target = pid || __MODULE__

    {:ok,
     Agent.get(target, fn state ->
       get_in(state, [:conversations, conversation_id]) || MapSet.new()
     end)}
  end

  @impl true
  def put_checkpoint(subscription_id, checkpoint, pid \\ nil) do
    target = pid || __MODULE__

    Helpers.emit_checkpoint_put(subscription_id)

    Agent.update(target, fn state ->
      put_in(state, [:checkpoints, subscription_id], checkpoint)
    end)
  end

  @impl true
  def get_checkpoint(subscription_id, pid \\ nil) do
    target = pid || __MODULE__

    case Agent.get(target, fn state -> get_in(state, [:checkpoints, subscription_id]) end) do
      nil ->
        Helpers.emit_checkpoint_get(subscription_id, false)

        {:error, :not_found}

      checkpoint ->
        Helpers.emit_checkpoint_get(subscription_id, true)

        {:ok, checkpoint}
    end
  end

  @impl true
  def delete_checkpoint(subscription_id, pid \\ nil) do
    target = pid || __MODULE__

    Agent.update(target, fn state ->
      {_, new_state} = pop_in(state, [:checkpoints, subscription_id])
      new_state
    end)
  end

  @impl true
  def put_dlq_entry(subscription_id, signal, reason, metadata, pid \\ nil) do
    target = pid || __MODULE__
    entry = Helpers.build_dlq_entry(subscription_id, signal, reason, metadata)
    entry_id = entry.id

    Agent.update(target, fn state ->
      put_in(state, [:dlq, entry_id], entry)
    end)

    Helpers.emit_dlq_put(subscription_id, entry_id)

    {:ok, entry_id}
  end

  @impl true
  def get_dlq_entries(subscription_id, pid \\ nil) do
    target = pid || __MODULE__

    entries =
      Agent.get(target, fn state ->
        state.dlq
        |> Map.values()
        |> Enum.filter(fn entry -> entry.subscription_id == subscription_id end)
        |> Enum.sort_by(fn entry -> entry.inserted_at end, DateTime)
      end)

    Helpers.emit_dlq_get(subscription_id, length(entries))

    {:ok, entries}
  end

  @impl true
  def delete_dlq_entry(entry_id, pid \\ nil) do
    target = pid || __MODULE__

    Agent.update(target, fn state ->
      {_, new_state} = pop_in(state, [:dlq, entry_id])
      new_state
    end)
  end

  @impl true
  def clear_dlq(subscription_id, pid \\ nil) do
    target = pid || __MODULE__

    Agent.update(target, fn state ->
      new_dlq =
        state.dlq
        |> Enum.reject(fn {_id, entry} -> entry.subscription_id == subscription_id end)
        |> Map.new()

      %{state | dlq: new_dlq}
    end)
  end

  @doc """
  Gets all signals in the journal.

  ## Returns

  A list of all signals stored in the journal

  ## Examples

      iex> Jido.Signal.Journal.Adapters.InMemory.put_signal(signal1)
      iex> Jido.Signal.Journal.Adapters.InMemory.put_signal(signal2)
      iex> signals = Jido.Signal.Journal.Adapters.InMemory.get_all_signals()
      iex> length(signals)
      2
  """
  @spec get_all_signals(pid() | nil) :: [Jido.Signal.t()]
  def get_all_signals(pid \\ nil) do
    target = pid || __MODULE__

    Agent.get(target, fn state ->
      state.signals
      |> Map.values()
    end)
  end
end
