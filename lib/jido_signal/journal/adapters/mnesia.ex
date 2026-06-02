defmodule Jido.Signal.Journal.Adapters.Mnesia do
  @moduledoc """
  Mnesia-based implementation of the Journal persistence behavior using native
  Erlang/OTP Mnesia.

  This adapter provides durable persistence that survives node restarts.

  ## Usage

      # Ensure Mnesia schema is created (one-time setup)
      :mnesia.create_schema([node()])
      :mnesia.start()

      # Initialize tables
      :ok = Jido.Signal.Journal.Adapters.Mnesia.init()

      # Use with journal
      {:ok, journal} = Jido.Signal.Journal.new(Jido.Signal.Journal.Adapters.Mnesia)
  """

  @behaviour Jido.Signal.Journal.Persistence

  alias Jido.Signal.ID
  alias Jido.Signal.Journal.Adapters.Mnesia.Tables
  alias Jido.Signal.Telemetry

  require Logger

  @compile {:no_warn_undefined, :mnesia}

  @tables [
    Tables.Signal,
    Tables.Cause,
    Tables.Effect,
    Tables.Conversation,
    Tables.Checkpoint,
    Tables.DLQ
  ]

  @impl true
  def init do
    with :ok <- ensure_started(),
         :ok <- create_tables() do
      wait_for_tables()
    end
  end

  defp ensure_started do
    case :mnesia.system_info(:is_running) do
      :no -> :mnesia.start()
      _ -> :ok
    end
  end

  defp create_tables do
    Enum.reduce_while(@tables, :ok, fn table, :ok ->
      case create_table(table) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          Logger.warning("Failed to create Mnesia table #{inspect(table)}: #{inspect(reason)}")
          {:halt, {:error, {:table_creation_failed, table, reason}}}
      end
    end)
  end

  defp wait_for_tables do
    case :mnesia.wait_for_tables(@tables, 5000) do
      :ok ->
        :ok

      {:timeout, tables} ->
        {:error, {:tables_not_available, tables}}

      {:error, reason} ->
        {:error, {:tables_not_available, reason}}
    end
  end

  @impl true
  def put_signal(signal, _pid) do
    start_time = System.monotonic_time(:microsecond)

    result =
      transaction(fn ->
        write(Tables.Signal, %Tables.Signal{id: signal.id, signal: signal})
      end)

    duration_us = System.monotonic_time(:microsecond) - start_time
    emit_telemetry(:put_signal, duration_us)

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_signal(signal_id, _pid) do
    start_time = System.monotonic_time(:microsecond)

    result =
      transaction(fn ->
        read(Tables.Signal, signal_id)
      end)

    duration_us = System.monotonic_time(:microsecond) - start_time
    emit_telemetry(:get_signal, duration_us)

    case result do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %Tables.Signal{signal: signal}} -> {:ok, signal}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def put_cause(cause_id, effect_id, _pid) do
    start_time = System.monotonic_time(:microsecond)

    result =
      transaction(fn ->
        effects =
          case read(Tables.Cause, cause_id) do
            nil -> MapSet.new([effect_id])
            %Tables.Cause{effects: existing} -> MapSet.put(existing, effect_id)
          end

        write(Tables.Cause, %Tables.Cause{cause_id: cause_id, effects: effects})

        causes =
          case read(Tables.Effect, effect_id) do
            nil -> MapSet.new([cause_id])
            %Tables.Effect{causes: existing} -> MapSet.put(existing, cause_id)
          end

        write(Tables.Effect, %Tables.Effect{effect_id: effect_id, causes: causes})
      end)

    duration_us = System.monotonic_time(:microsecond) - start_time
    emit_telemetry(:put_cause, duration_us)

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_effects(signal_id, _pid) do
    start_time = System.monotonic_time(:microsecond)

    result =
      transaction(fn ->
        case read(Tables.Cause, signal_id) do
          nil -> MapSet.new()
          %Tables.Cause{effects: effects} -> effects
        end
      end)

    duration_us = System.monotonic_time(:microsecond) - start_time
    emit_telemetry(:get_effects, duration_us)

    result
  end

  @impl true
  def get_cause(signal_id, _pid) do
    start_time = System.monotonic_time(:microsecond)

    result =
      transaction(fn ->
        extract_cause_id(signal_id)
      end)

    duration_us = System.monotonic_time(:microsecond) - start_time
    emit_telemetry(:get_cause, duration_us)

    case result do
      {:ok, nil} -> {:error, :not_found}
      {:ok, cause_id} -> {:ok, cause_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_cause_id(signal_id) do
    case read(Tables.Effect, signal_id) do
      nil -> nil
      %Tables.Effect{causes: causes} -> first_cause_id(causes)
    end
  end

  defp first_cause_id(causes) do
    case MapSet.to_list(causes) do
      [cause_id | _] -> cause_id
      [] -> nil
    end
  end

  @impl true
  def put_conversation(conversation_id, signal_id, _pid) do
    start_time = System.monotonic_time(:microsecond)

    result =
      transaction(fn ->
        signals =
          case read(Tables.Conversation, conversation_id) do
            nil -> MapSet.new([signal_id])
            %Tables.Conversation{signals: existing} -> MapSet.put(existing, signal_id)
          end

        write(Tables.Conversation, %Tables.Conversation{
          conversation_id: conversation_id,
          signals: signals
        })
      end)

    duration_us = System.monotonic_time(:microsecond) - start_time
    emit_telemetry(:put_conversation, duration_us)

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_conversation(conversation_id, _pid) do
    start_time = System.monotonic_time(:microsecond)

    result =
      transaction(fn ->
        case read(Tables.Conversation, conversation_id) do
          nil -> MapSet.new()
          %Tables.Conversation{signals: signals} -> signals
        end
      end)

    duration_us = System.monotonic_time(:microsecond) - start_time
    emit_telemetry(:get_conversation, duration_us)

    result
  end

  @impl true
  def put_checkpoint(subscription_id, checkpoint, _pid) do
    start_time = System.monotonic_time(:microsecond)

    result =
      transaction(fn ->
        write(Tables.Checkpoint, %Tables.Checkpoint{
          subscription_id: subscription_id,
          checkpoint: checkpoint
        })
      end)

    duration_us = System.monotonic_time(:microsecond) - start_time
    emit_telemetry(:put_checkpoint, duration_us)

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_checkpoint(subscription_id, _pid) do
    start_time = System.monotonic_time(:microsecond)

    result =
      transaction(fn ->
        read(Tables.Checkpoint, subscription_id)
      end)

    duration_us = System.monotonic_time(:microsecond) - start_time
    emit_telemetry(:get_checkpoint, duration_us)

    case result do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %Tables.Checkpoint{checkpoint: checkpoint}} -> {:ok, checkpoint}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete_checkpoint(subscription_id, _pid) do
    start_time = System.monotonic_time(:microsecond)

    result =
      transaction(fn ->
        delete(Tables.Checkpoint, subscription_id)
      end)

    duration_us = System.monotonic_time(:microsecond) - start_time
    emit_telemetry(:delete_checkpoint, duration_us)

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def put_dlq_entry(subscription_id, signal, reason, metadata, _pid) do
    start_time = System.monotonic_time(:microsecond)
    entry_id = ID.generate!()
    inserted_at = DateTime.utc_now()

    result =
      transaction(fn ->
        write(Tables.DLQ, %Tables.DLQ{
          id: entry_id,
          subscription_id: subscription_id,
          signal: signal,
          reason: reason,
          metadata: metadata,
          inserted_at: inserted_at
        })
      end)

    duration_us = System.monotonic_time(:microsecond) - start_time
    emit_telemetry(:put_dlq_entry, duration_us)

    Telemetry.execute(
      [:jido, :signal, :journal, :dlq, :put],
      %{},
      %{subscription_id: subscription_id, entry_id: entry_id}
    )

    case result do
      {:ok, _} -> {:ok, entry_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_dlq_entries(subscription_id, _pid) do
    start_time = System.monotonic_time(:microsecond)

    result =
      transaction(fn ->
        dlq_entries_for_subscription(subscription_id)
      end)

    duration_us = System.monotonic_time(:microsecond) - start_time
    emit_telemetry(:get_dlq_entries, duration_us)

    case result do
      {:ok, records} ->
        entries =
          records
          |> Enum.map(fn %Tables.DLQ{
                           id: id,
                           subscription_id: sub_id,
                           signal: signal,
                           reason: reason,
                           metadata: metadata,
                           inserted_at: inserted_at
                         } ->
            %{
              id: id,
              subscription_id: sub_id,
              signal: signal,
              reason: reason,
              metadata: metadata,
              inserted_at: inserted_at
            }
          end)
          |> Enum.sort_by(fn entry -> entry.inserted_at end, DateTime)

        Telemetry.execute(
          [:jido, :signal, :journal, :dlq, :get],
          %{count: length(entries)},
          %{subscription_id: subscription_id}
        )

        {:ok, entries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def delete_dlq_entry(entry_id, _pid) do
    start_time = System.monotonic_time(:microsecond)

    result =
      transaction(fn ->
        delete(Tables.DLQ, entry_id)
      end)

    duration_us = System.monotonic_time(:microsecond) - start_time
    emit_telemetry(:delete_dlq_entry, duration_us)

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def clear_dlq(subscription_id, _pid) do
    start_time = System.monotonic_time(:microsecond)

    result =
      transaction(fn ->
        records = dlq_entries_for_subscription(subscription_id)

        Enum.each(records, fn record ->
          delete(Tables.DLQ, record.id)
        end)
      end)

    duration_us = System.monotonic_time(:microsecond) - start_time
    emit_telemetry(:clear_dlq, duration_us)

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit_telemetry(operation, duration_us) do
    Telemetry.execute(
      [:jido, :signal, :journal, :mnesia, :operation],
      %{duration_us: duration_us},
      %{operation: operation}
    )
  end

  defp create_table(table) do
    opts =
      [attributes: table.attributes(), type: table.type(), disc_copies: [node()]]
      |> put_index(table.index())

    case :mnesia.create_table(table, opts) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, _table}} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp put_index(opts, []), do: opts
  defp put_index(opts, index), do: Keyword.put(opts, :index, index)

  defp transaction(fun) do
    case :mnesia.transaction(fun) do
      {:atomic, result} -> {:ok, result}
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp read(table, key) do
    case :mnesia.read(table, key, :read) do
      [] -> nil
      [record | _] -> table.from_record(record)
    end
  end

  defp write(table, value), do: :mnesia.write(table.to_record(value))

  defp delete(table, key), do: :mnesia.delete(table, key, :write)

  defp dlq_entries_for_subscription(subscription_id) do
    Tables.DLQ
    |> :mnesia.index_read(subscription_id, :subscription_id)
    |> Enum.map(&Tables.DLQ.from_record/1)
  end
end
