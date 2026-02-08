defmodule Jido.Signal.Journal.Adapters.ETS do
  @moduledoc """
  ETS-based implementation of the Journal persistence behavior.
  Uses separate ETS tables for signals, causes, effects, and conversations.

  ## Configuration
  The adapter requires a prefix for table names to allow multiple instances:

      {:ok, _pid} = Jido.Signal.Journal.Adapters.ETS.start_link("my_journal_")
      {:ok, journal} = Jido.Signal.Journal.new(Jido.Signal.Journal.Adapters.ETS)

  This will create tables with names:
    - :my_journal_signals
    - :my_journal_causes
    - :my_journal_effects
    - :my_journal_conversations
  """
  @behaviour Jido.Signal.Journal.Persistence

  use GenServer

  alias Jido.Signal.Journal.Adapters.Helpers

  @schema Zoi.struct(
            __MODULE__,
            %{
              signals_table: Zoi.any() |> Zoi.nullable() |> Zoi.optional(),
              causes_table: Zoi.any() |> Zoi.nullable() |> Zoi.optional(),
              effects_table: Zoi.any() |> Zoi.nullable() |> Zoi.optional(),
              conversations_table: Zoi.any() |> Zoi.nullable() |> Zoi.optional(),
              checkpoints_table: Zoi.any() |> Zoi.nullable() |> Zoi.optional(),
              dlq_table: Zoi.any() |> Zoi.nullable() |> Zoi.optional(),
              dlq_subscription_index_table: Zoi.any() |> Zoi.nullable() |> Zoi.optional()
            }
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for ETS adapter"
  def schema, do: @schema

  # Client API

  @doc """
  Starts the ETS adapter with the given table name prefix.
  """
  def start_link(prefix) when is_binary(prefix) do
    GenServer.start_link(__MODULE__, prefix)
  end

  @impl Jido.Signal.Journal.Persistence
  def init do
    # Generate a unique prefix for this instance
    prefix = "journal_#{System.unique_integer([:positive, :monotonic])}_"

    case start_link(prefix) do
      {:ok, pid} -> {:ok, pid}
      error -> error
    end
  end

  @impl Jido.Signal.Journal.Persistence
  def put_signal(signal, pid) do
    safe_genserver_call(pid, {:put_signal, signal})
  end

  @impl Jido.Signal.Journal.Persistence
  def get_signal(signal_id, pid) do
    case get_table_refs(pid) do
      {:ok, %{signals_table: signals_table}} ->
        case :ets.lookup(signals_table, signal_id) do
          [{^signal_id, signal}] -> {:ok, signal}
          [] -> {:error, :not_found}
        end

      :error ->
        GenServer.call(pid, {:get_signal, signal_id})
    end
  end

  @impl Jido.Signal.Journal.Persistence
  def put_cause(cause_id, effect_id, pid) do
    GenServer.call(pid, {:put_cause, cause_id, effect_id})
  end

  @impl Jido.Signal.Journal.Persistence
  def get_effects(signal_id, pid) do
    case get_table_refs(pid) do
      {:ok, %{causes_table: causes_table}} ->
        effects =
          case :ets.lookup(causes_table, signal_id) do
            [{^signal_id, found}] -> found
            [] -> MapSet.new()
          end

        {:ok, effects}

      :error ->
        GenServer.call(pid, {:get_effects, signal_id})
    end
  end

  @impl Jido.Signal.Journal.Persistence
  def get_cause(signal_id, pid) do
    case get_table_refs(pid) do
      {:ok, %{effects_table: effects_table}} ->
        case :ets.lookup(effects_table, signal_id) do
          [{^signal_id, causes}] ->
            first_cause(causes)

          [] ->
            {:error, :not_found}
        end

      :error ->
        GenServer.call(pid, {:get_cause, signal_id})
    end
  end

  @impl Jido.Signal.Journal.Persistence
  def put_conversation(conversation_id, signal_id, pid) do
    GenServer.call(pid, {:put_conversation, conversation_id, signal_id})
  end

  @impl Jido.Signal.Journal.Persistence
  def get_conversation(conversation_id, pid) do
    case get_table_refs(pid) do
      {:ok, %{conversations_table: conversations_table}} ->
        signals =
          case :ets.lookup(conversations_table, conversation_id) do
            [{^conversation_id, found}] -> found
            [] -> MapSet.new()
          end

        {:ok, signals}

      :error ->
        GenServer.call(pid, {:get_conversation, conversation_id})
    end
  end

  @impl Jido.Signal.Journal.Persistence
  def put_checkpoint(subscription_id, checkpoint, pid) do
    GenServer.call(pid, {:put_checkpoint, subscription_id, checkpoint})
  end

  @impl Jido.Signal.Journal.Persistence
  def get_checkpoint(subscription_id, pid) do
    case get_table_refs(pid) do
      {:ok, %{checkpoints_table: checkpoints_table}} ->
        case :ets.lookup(checkpoints_table, subscription_id) do
          [{^subscription_id, checkpoint}] ->
            Helpers.emit_checkpoint_get(subscription_id, true)
            {:ok, checkpoint}

          [] ->
            Helpers.emit_checkpoint_get(subscription_id, false)
            {:error, :not_found}
        end

      :error ->
        GenServer.call(pid, {:get_checkpoint, subscription_id})
    end
  end

  @impl Jido.Signal.Journal.Persistence
  def delete_checkpoint(subscription_id, pid) do
    GenServer.call(pid, {:delete_checkpoint, subscription_id})
  end

  @impl Jido.Signal.Journal.Persistence
  def put_dlq_entry(subscription_id, signal, reason, metadata, pid) do
    GenServer.call(pid, {:put_dlq_entry, subscription_id, signal, reason, metadata})
  end

  @impl Jido.Signal.Journal.Persistence
  def get_dlq_entries(subscription_id, pid) do
    get_dlq_entries(subscription_id, pid, [])
  end

  @impl Jido.Signal.Journal.Persistence
  def get_dlq_entries(subscription_id, pid, opts) when is_list(opts) do
    limit = Keyword.get(opts, :limit, :infinity)

    case get_table_refs(pid) do
      {:ok, table_refs} ->
        entries =
          table_refs
          |> dlq_entries_for_subscription(subscription_id)
          |> maybe_limit_entries(limit)

        Helpers.emit_dlq_get(subscription_id, length(entries))
        {:ok, entries}

      :error ->
        GenServer.call(pid, {:get_dlq_entries, subscription_id, opts})
    end
  end

  @impl Jido.Signal.Journal.Persistence
  def get_dlq_entries(subscription_id, pid, _opts) do
    GenServer.call(pid, {:get_dlq_entries, subscription_id})
  end

  @impl Jido.Signal.Journal.Persistence
  def delete_dlq_entry(entry_id, pid) do
    GenServer.call(pid, {:delete_dlq_entry, entry_id})
  end

  @impl Jido.Signal.Journal.Persistence
  def clear_dlq(subscription_id, pid) do
    clear_dlq(subscription_id, pid, [])
  end

  @impl Jido.Signal.Journal.Persistence
  def clear_dlq(subscription_id, pid, opts) when is_list(opts) do
    GenServer.call(pid, {:clear_dlq, subscription_id, opts})
  end

  @impl Jido.Signal.Journal.Persistence
  def clear_dlq(subscription_id, pid, _opts) do
    GenServer.call(pid, {:clear_dlq, subscription_id})
  end

  @doc """
  Gets all signals in the journal.
  """
  def get_all_signals(pid) do
    get_all_signals(pid, [])
  end

  @doc """
  Gets signals in the journal with optional bounded reads.

  ## Options
  - `:limit` - Maximum number of signals to return
  """
  @spec get_all_signals(pid(), keyword()) :: [Jido.Signal.t()]
  def get_all_signals(pid, opts) when is_list(opts) do
    limit = Keyword.get(opts, :limit, :infinity)

    case get_table_refs(pid) do
      {:ok, %{signals_table: signals_table}} ->
        select_signals(signals_table, limit)

      :error ->
        GenServer.call(pid, :get_all_signals)
        |> maybe_limit_entries(limit)
    end
  end

  @doc """
  Cleans up all ETS tables used by this adapter instance.

  Returns `:ok` if the adapter process is already gone.
  """
  def cleanup(pid_or_name) do
    case GenServer.whereis(pid_or_name) do
      nil ->
        :ok

      _pid ->
        try do
          GenServer.call(pid_or_name, :cleanup)
        catch
          :exit, :noproc -> :ok
          :exit, {:noproc, _} -> :ok
          :exit, :normal -> :ok
          :exit, :shutdown -> :ok
          :exit, {:shutdown, _} -> :ok
        end
    end
  end

  # Server Callbacks

  @doc """
  Initializes the ETS adapter with the given table name prefix.

  ## Parameters

  - `prefix`: The prefix to use for table names

  ## Returns

  - `{:ok, adapter}` if initialization succeeds
  - `{:error, reason}` if initialization fails

  ## Examples

      iex> {:ok, adapter} = Jido.Signal.Journal.Adapters.ETS.init("my_journal_")
      iex> adapter.signals_table
      :my_journal_signals_...
  """
  @spec init(String.t()) :: {:ok, t()} | {:error, term()}
  @impl GenServer
  def init(_prefix) do
    table_opts = [:set, :protected, read_concurrency: true]

    adapter = %__MODULE__{
      signals_table: :ets.new(:signals, table_opts),
      causes_table: :ets.new(:causes, table_opts),
      effects_table: :ets.new(:effects, table_opts),
      conversations_table: :ets.new(:conversations, table_opts),
      checkpoints_table: :ets.new(:checkpoints, table_opts),
      dlq_table: :ets.new(:dlq, table_opts),
      dlq_subscription_index_table:
        :ets.new(:dlq_subscription_index, [:duplicate_bag, :protected, read_concurrency: true])
    }

    cache_table_refs(self(), adapter)

    {:ok, adapter}
  end

  @doc """
  Handles GenServer calls for signal operations.

  ## Parameters

  - `{:put_signal, signal}` - Stores a signal in the journal
  - `{:get_signal, signal_id}` - Retrieves a signal by ID
  - `{:put_cause, cause_id, effect_id}` - Records a cause-effect relationship
  - `{:get_effects, signal_id}` - Gets all effects for a signal
  - `{:get_cause, signal_id}` - Gets the cause for a signal
  - `{:put_conversation, conversation_id, signal_id}` - Adds a signal to a conversation
  - `{:get_conversation, conversation_id}` - Gets all signals in a conversation
  - `:get_all_signals` - Gets all signals in the journal
  - `:cleanup` - Cleans up all ETS tables

  ## Returns

  - `{:reply, result, adapter}` for successful operations
  - `{:reply, {:error, reason}, adapter}` for failed operations
  """
  @spec handle_call(term(), {pid(), term()}, t()) :: {:reply, term(), t()}
  @impl GenServer
  def handle_call({:put_signal, signal}, _from, adapter) do
    true = :ets.insert(adapter.signals_table, {signal.id, signal})
    {:reply, :ok, adapter}
  end

  @impl GenServer
  def handle_call({:get_signal, signal_id}, _from, adapter) do
    reply =
      case :ets.lookup(adapter.signals_table, signal_id) do
        [{^signal_id, signal}] -> {:ok, signal}
        [] -> {:error, :not_found}
      end

    {:reply, reply, adapter}
  end

  @impl GenServer
  def handle_call({:put_cause, cause_id, effect_id}, _from, adapter) do
    # Update causes
    effects =
      case :ets.lookup(adapter.causes_table, cause_id) do
        [{^cause_id, existing}] -> MapSet.put(existing, effect_id)
        [] -> MapSet.new([effect_id])
      end

    true = :ets.insert(adapter.causes_table, {cause_id, effects})

    # Update effects
    causes =
      case :ets.lookup(adapter.effects_table, effect_id) do
        [{^effect_id, existing}] -> MapSet.put(existing, cause_id)
        [] -> MapSet.new([cause_id])
      end

    true = :ets.insert(adapter.effects_table, {effect_id, causes})
    {:reply, :ok, adapter}
  end

  @impl GenServer
  def handle_call({:get_effects, signal_id}, _from, adapter) do
    effects =
      case :ets.lookup(adapter.causes_table, signal_id) do
        [{^signal_id, effects}] -> effects
        [] -> MapSet.new()
      end

    {:reply, {:ok, effects}, adapter}
  end

  @impl GenServer
  def handle_call({:get_cause, signal_id}, _from, adapter) do
    reply =
      case :ets.lookup(adapter.effects_table, signal_id) do
        [{^signal_id, causes}] ->
          case MapSet.to_list(causes) do
            [cause_id | _] -> {:ok, cause_id}
            [] -> {:error, :not_found}
          end

        [] ->
          {:error, :not_found}
      end

    {:reply, reply, adapter}
  end

  @impl GenServer
  def handle_call({:put_conversation, conversation_id, signal_id}, _from, adapter) do
    signals =
      case :ets.lookup(adapter.conversations_table, conversation_id) do
        [{^conversation_id, existing}] -> MapSet.put(existing, signal_id)
        [] -> MapSet.new([signal_id])
      end

    true = :ets.insert(adapter.conversations_table, {conversation_id, signals})
    {:reply, :ok, adapter}
  end

  @impl GenServer
  def handle_call({:get_conversation, conversation_id}, _from, adapter) do
    signals =
      case :ets.lookup(adapter.conversations_table, conversation_id) do
        [{^conversation_id, signals}] -> signals
        [] -> MapSet.new()
      end

    {:reply, {:ok, signals}, adapter}
  end

  @impl GenServer
  def handle_call({:put_checkpoint, subscription_id, checkpoint}, _from, adapter) do
    Helpers.emit_checkpoint_put(subscription_id)

    true = :ets.insert(adapter.checkpoints_table, {subscription_id, checkpoint})
    {:reply, :ok, adapter}
  end

  @impl GenServer
  def handle_call({:get_checkpoint, subscription_id}, _from, adapter) do
    reply =
      case :ets.lookup(adapter.checkpoints_table, subscription_id) do
        [{^subscription_id, checkpoint}] ->
          Helpers.emit_checkpoint_get(subscription_id, true)

          {:ok, checkpoint}

        [] ->
          Helpers.emit_checkpoint_get(subscription_id, false)

          {:error, :not_found}
      end

    {:reply, reply, adapter}
  end

  @impl GenServer
  def handle_call({:delete_checkpoint, subscription_id}, _from, adapter) do
    :ets.delete(adapter.checkpoints_table, subscription_id)
    {:reply, :ok, adapter}
  end

  @impl GenServer
  def handle_call({:put_dlq_entry, subscription_id, signal, reason, metadata}, _from, adapter) do
    entry = Helpers.build_dlq_entry(subscription_id, signal, reason, metadata)
    entry_id = entry.id

    true = :ets.insert(adapter.dlq_table, {entry_id, entry})
    true = :ets.insert(adapter.dlq_subscription_index_table, {subscription_id, entry_id})

    Helpers.emit_dlq_put(subscription_id, entry_id)

    {:reply, {:ok, entry_id}, adapter}
  end

  @impl GenServer
  def handle_call({:get_dlq_entries, subscription_id}, _from, adapter) do
    entries = get_dlq_entries_for_subscription(adapter, subscription_id, :infinity)
    {:reply, {:ok, entries}, adapter}
  end

  @impl GenServer
  def handle_call({:get_dlq_entries, subscription_id, opts}, _from, adapter) when is_list(opts) do
    limit = Keyword.get(opts, :limit, :infinity)
    entries = get_dlq_entries_for_subscription(adapter, subscription_id, limit)
    {:reply, {:ok, entries}, adapter}
  end

  @impl GenServer
  def handle_call({:delete_dlq_entry, entry_id}, _from, adapter) do
    maybe_delete_dlq_index(adapter, entry_id)
    :ets.delete(adapter.dlq_table, entry_id)
    {:reply, :ok, adapter}
  end

  @impl GenServer
  def handle_call({:clear_dlq, subscription_id}, _from, adapter) do
    clear_dlq_entries(adapter, subscription_id, :infinity)
    {:reply, :ok, adapter}
  end

  @impl GenServer
  def handle_call({:clear_dlq, subscription_id, opts}, _from, adapter) when is_list(opts) do
    limit = Keyword.get(opts, :limit, :infinity)
    clear_dlq_entries(adapter, subscription_id, limit)
    {:reply, :ok, adapter}
  end

  @impl GenServer
  def handle_call(:get_all_signals, _from, adapter) do
    signals = select_signals(adapter.signals_table, :infinity)

    {:reply, signals, adapter}
  end

  @impl GenServer
  def handle_call(:tables, _from, adapter) do
    {:reply, table_refs_from_adapter(adapter), adapter}
  end

  @impl GenServer
  def handle_call(:cleanup, _from, adapter) do
    clear_cached_table_refs(self())
    delete_tables(adapter)

    {:reply, :ok, adapter}
  end

  @impl GenServer
  def terminate(_reason, adapter) do
    clear_cached_table_refs(self())
    delete_tables(adapter)
    :ok
  end

  defp delete_tables(adapter) do
    [
      adapter.signals_table,
      adapter.causes_table,
      adapter.effects_table,
      adapter.conversations_table,
      adapter.checkpoints_table,
      adapter.dlq_table,
      adapter.dlq_subscription_index_table
    ]
    |> Enum.each(fn table ->
      case :ets.info(table) do
        :undefined -> :ok
        _info -> :ets.delete(table)
      end
    end)
  end

  defp maybe_delete_dlq_index(adapter, entry_id) do
    case :ets.lookup(adapter.dlq_table, entry_id) do
      [{^entry_id, %{subscription_id: subscription_id}}] ->
        delete_dlq_index_entry(adapter, subscription_id, entry_id)

      _ ->
        :ok
    end
  end

  defp delete_dlq_index_entry(%{dlq_subscription_index_table: nil}, _subscription_id, _entry_id),
    do: :ok

  defp delete_dlq_index_entry(adapter, subscription_id, entry_id) do
    :ets.match_delete(adapter.dlq_subscription_index_table, {subscription_id, entry_id})
    :ok
  catch
    :error, :badarg ->
      # Direct-read callers can hit protected tables from non-owner processes.
      :ok
  end

  defp maybe_limit_entries(entries, :infinity), do: entries

  defp maybe_limit_entries(entries, limit) when is_integer(limit) and limit >= 0,
    do: Enum.take(entries, limit)

  defp maybe_limit_entries(entries, _invalid_limit), do: entries

  defp get_dlq_entries_for_subscription(adapter, subscription_id, limit) do
    entries =
      adapter
      |> dlq_entries_for_subscription(subscription_id)
      |> maybe_limit_entries(limit)

    Helpers.emit_dlq_get(subscription_id, length(entries))
    entries
  end

  defp clear_dlq_entries(adapter, subscription_id, limit) do
    entry_ids = dlq_entry_ids_for_subscription(adapter, subscription_id, limit)

    Enum.each(entry_ids, fn entry_id ->
      :ets.delete(adapter.dlq_table, entry_id)
      delete_dlq_index_entry(adapter, subscription_id, entry_id)
    end)
  end

  defp dlq_entries_for_subscription(
         %{dlq_subscription_index_table: nil} = adapter,
         subscription_id
       ) do
    adapter
    |> dlq_entries_with_ids_for_subscription(subscription_id)
    |> Enum.map(fn {_entry_id, entry} -> entry end)
  end

  defp dlq_entries_for_subscription(adapter, subscription_id) do
    adapter
    |> dlq_entries_with_ids_for_subscription(subscription_id)
    |> Enum.map(fn {_entry_id, entry} -> entry end)
  end

  defp dlq_entry_ids_for_subscription(adapter, subscription_id, limit) do
    adapter
    |> dlq_entries_with_ids_for_subscription(subscription_id)
    |> maybe_limit_entries(limit)
    |> Enum.map(fn {entry_id, _entry} -> entry_id end)
  end

  defp dlq_entries_with_ids_for_subscription(
         %{dlq_subscription_index_table: nil} = adapter,
         subscription_id
       ) do
    :ets.foldl(
      fn {entry_id, entry}, acc ->
        if entry.subscription_id == subscription_id do
          [{entry_id, entry} | acc]
        else
          acc
        end
      end,
      [],
      adapter.dlq_table
    )
    |> Enum.sort_by(fn {_entry_id, entry} -> entry.inserted_at end, DateTime)
  end

  defp dlq_entries_with_ids_for_subscription(adapter, subscription_id) do
    adapter.dlq_subscription_index_table
    |> :ets.lookup(subscription_id)
    |> Enum.map(fn {^subscription_id, entry_id} -> entry_id end)
    |> Enum.reduce([], fn entry_id, acc ->
      case :ets.lookup(adapter.dlq_table, entry_id) do
        [{^entry_id, entry}] ->
          [{entry_id, entry} | acc]

        [] ->
          # Keep index table self-healing when stale references are encountered.
          delete_dlq_index_entry(adapter, subscription_id, entry_id)
          acc
      end
    end)
    |> Enum.sort_by(fn {_entry_id, entry} -> entry.inserted_at end, DateTime)
  end

  defp select_signals(signals_table, :infinity) do
    :ets.select(signals_table, [{{:_, :"$1"}, [], [:"$1"]}])
  end

  defp select_signals(signals_table, limit) when is_integer(limit) and limit >= 0 do
    case :ets.select(signals_table, [{{:_, :"$1"}, [], [:"$1"]}], limit) do
      :"$end_of_table" -> []
      {signals, _continuation} -> signals
    end
  end

  defp select_signals(signals_table, _invalid_limit) do
    select_signals(signals_table, :infinity)
  end

  defp table_refs_from_adapter(adapter) do
    %{
      signals_table: adapter.signals_table,
      causes_table: adapter.causes_table,
      effects_table: adapter.effects_table,
      conversations_table: adapter.conversations_table,
      checkpoints_table: adapter.checkpoints_table,
      dlq_table: adapter.dlq_table,
      dlq_subscription_index_table: adapter.dlq_subscription_index_table
    }
  end

  defp table_cache_key(pid), do: {__MODULE__, :tables, pid}

  defp cache_table_refs(pid, adapter) do
    :persistent_term.put(table_cache_key(pid), table_refs_from_adapter(adapter))
    :ok
  end

  defp clear_cached_table_refs(pid) do
    _ = :persistent_term.erase(table_cache_key(pid))
    :ok
  end

  defp get_table_refs(pid) when is_pid(pid) do
    key = table_cache_key(pid)

    case :persistent_term.get(key, :not_found) do
      :not_found ->
        maybe_fetch_and_cache_table_refs(pid, key)

      refs ->
        if table_refs_available?(refs) do
          {:ok, refs}
        else
          clear_cached_table_refs(pid)
          maybe_fetch_and_cache_table_refs(pid, key)
        end
    end
  end

  defp get_table_refs(_pid), do: :error

  defp maybe_fetch_and_cache_table_refs(pid, key) do
    case fetch_table_refs(pid) do
      {:ok, refs} ->
        if table_refs_available?(refs) do
          :persistent_term.put(key, refs)
          {:ok, refs}
        else
          :error
        end

      :error ->
        :error
    end
  end

  defp fetch_table_refs(pid) do
    {:ok, GenServer.call(pid, :tables, 50)}
  catch
    :exit, _ -> :error
  end

  defp first_cause(causes) do
    case MapSet.to_list(causes) do
      [cause_id | _] -> {:ok, cause_id}
      [] -> {:error, :not_found}
    end
  end

  defp table_refs_available?(refs) when is_map(refs) do
    refs
    |> Map.values()
    |> Enum.reject(&is_nil/1)
    |> Enum.all?(fn table -> :ets.info(table) != :undefined end)
  end

  defp table_refs_available?(_refs), do: false

  defp safe_genserver_call(pid, message) do
    GenServer.call(pid, message)
  catch
    :exit, reason -> {:error, normalize_exit_reason(reason)}
  end

  defp normalize_exit_reason({:noproc, _}), do: :adapter_unavailable
  defp normalize_exit_reason(:noproc), do: :adapter_unavailable
  defp normalize_exit_reason(reason), do: reason
end
