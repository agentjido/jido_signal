defmodule Jido.Signal.Bus.PersistentSubscription do
  @moduledoc """
  A GenServer that manages persistent subscription state and checkpoints for a single subscriber.

  This module maintains the subscription state for a client, tracking which signals have been
  acknowledged and allowing clients to resume from their last checkpoint after disconnection.
  Each instance maps 1:1 to a bus subscriber and is managed as a child of the Bus's dynamic supervisor.
  """
  use GenServer

  alias Jido.Signal.Bus
  alias Jido.Signal.Dispatch
  alias Jido.Signal.ID
  alias Jido.Signal.Telemetry

  require Logger

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              bus_pid: Zoi.any(),
              bus_subscription: Zoi.any() |> Zoi.nullable() |> Zoi.optional(),
              client_pid: Zoi.any(),
              checkpoint: Zoi.default(Zoi.integer(), 0) |> Zoi.optional(),
              max_in_flight: Zoi.default(Zoi.integer(), 1000) |> Zoi.optional(),
              max_pending: Zoi.default(Zoi.integer(), 10_000) |> Zoi.optional(),
              in_flight_signals: Zoi.default(Zoi.map(), %{}) |> Zoi.optional(),
              pending_signals: Zoi.default(Zoi.map(), %{}) |> Zoi.optional(),
              max_attempts: Zoi.default(Zoi.integer(), 5) |> Zoi.optional(),
              attempts: Zoi.default(Zoi.map(), %{}) |> Zoi.optional(),
              retry_interval: Zoi.default(Zoi.integer(), 100) |> Zoi.optional(),
              retry_timer_ref: Zoi.any() |> Zoi.nullable() |> Zoi.optional(),
              task_supervisor: Zoi.any() |> Zoi.nullable() |> Zoi.optional(),
              journal_adapter: Zoi.atom() |> Zoi.nullable() |> Zoi.optional(),
              journal_pid: Zoi.any() |> Zoi.nullable() |> Zoi.optional(),
              checkpoint_key: Zoi.string() |> Zoi.nullable() |> Zoi.optional()
            }
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for PersistentSubscription"
  def schema, do: @schema

  # Client API

  @doc """
  Starts a new persistent subscription process.

  Options:
  - id: Unique identifier for this subscription (required)
  - bus_pid: PID of the bus this subscription belongs to (required)
  - path: Signal path pattern to subscribe to (required)
  - start_from: Where to start reading signals from (:origin, :current, or timestamp)
  - max_in_flight: Maximum number of unacknowledged signals (default: 1000)
  - max_pending: Maximum number of pending signals before backpressure (default: 10_000)
  - client_pid: PID of the client process (required)
  - dispatch_opts: Additional dispatch options for the subscription
  """
  def start_link(opts) do
    id = Keyword.get(opts, :id) || ID.generate!()
    opts = Keyword.put(opts, :id, id)

    # Validate start_from value and set default if invalid
    opts =
      case Keyword.get(opts, :start_from, :origin) do
        :origin ->
          opts

        :current ->
          opts

        timestamp when is_integer(timestamp) and timestamp >= 0 ->
          opts

        _invalid ->
          Keyword.put(opts, :start_from, :origin)
      end

    GenServer.start_link(__MODULE__, opts, name: via_tuple(id))
  end

  defdelegate via_tuple(id), to: Jido.Signal.Util
  defdelegate whereis(id), to: Jido.Signal.Util

  @impl GenServer
  def init(opts) do
    # Extract the bus subscription
    bus_subscription = Keyword.fetch!(opts, :bus_subscription)

    id = Keyword.fetch!(opts, :id)
    journal_adapter = Keyword.get(opts, :journal_adapter)
    journal_pid = Keyword.get(opts, :journal_pid)
    bus_name = Keyword.get(opts, :bus_name, :unknown)

    # Compute checkpoint key (unique per bus + subscription)
    checkpoint_key = "#{bus_name}:#{id}"

    # Load checkpoint from journal if adapter is configured
    loaded_checkpoint =
      if journal_adapter do
        case journal_adapter.get_checkpoint(checkpoint_key, journal_pid) do
          {:ok, cp} ->
            cp

          {:error, :not_found} ->
            0

          {:error, reason} ->
            Logger.warning("Failed to load checkpoint for #{checkpoint_key}: #{inspect(reason)}")

            0
        end
      else
        Keyword.get(opts, :checkpoint, 0)
      end

    state = %__MODULE__{
      id: id,
      bus_pid: Keyword.fetch!(opts, :bus_pid),
      bus_subscription: bus_subscription,
      client_pid: Keyword.get(opts, :client_pid),
      checkpoint: loaded_checkpoint,
      max_in_flight: Keyword.get(opts, :max_in_flight, 1000),
      max_pending: Keyword.get(opts, :max_pending, 10_000),
      max_attempts: Keyword.get(opts, :max_attempts, 5),
      retry_interval: Keyword.get(opts, :retry_interval, 100),
      task_supervisor: Keyword.get(opts, :task_supervisor, Jido.Signal.TaskSupervisor),
      in_flight_signals: %{},
      pending_signals: %{},
      attempts: %{},
      journal_adapter: journal_adapter,
      journal_pid: journal_pid,
      checkpoint_key: checkpoint_key
    }

    # Monitor the client process if specified
    if state.client_pid && Process.alive?(state.client_pid) do
      Process.monitor(state.client_pid)
    end

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:ack, signal_log_id}, _from, state) when is_binary(signal_log_id) do
    # Remove the acknowledged signal from in-flight
    new_in_flight = Map.delete(state.in_flight_signals, signal_log_id)

    # Extract timestamp from UUID7 for checkpoint comparison
    timestamp = ID.extract_timestamp(signal_log_id)

    # Update checkpoint if this is a higher number
    new_checkpoint = max(state.checkpoint, timestamp)

    # Persist checkpoint if journal adapter is configured
    persist_checkpoint(state, new_checkpoint)

    # Update state
    new_state = %{state | in_flight_signals: new_in_flight, checkpoint: new_checkpoint}

    # Process any pending signals
    new_state = process_pending_signals(new_state)

    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:ack, signal_log_ids}, _from, state) when is_list(signal_log_ids) do
    # Remove all acknowledged signals from in-flight
    new_in_flight =
      Enum.reduce(signal_log_ids, state.in_flight_signals, fn id, acc ->
        Map.delete(acc, id)
      end)

    # Extract timestamps from all UUIDs and find the highest
    highest_timestamp =
      signal_log_ids
      |> Enum.map(&ID.extract_timestamp/1)
      |> Enum.max()

    # Update checkpoint if this is a higher number
    new_checkpoint = max(state.checkpoint, highest_timestamp)

    # Persist checkpoint if journal adapter is configured
    persist_checkpoint(state, new_checkpoint)

    # Update state
    new_state = %{state | in_flight_signals: new_in_flight, checkpoint: new_checkpoint}

    # Process any pending signals
    new_state = process_pending_signals(new_state)

    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:ack, _invalid_arg}, _from, state) do
    {:reply, {:error, :invalid_ack_argument}, state}
  end

  @impl GenServer
  def handle_call({:signal, {signal_log_id, signal}}, _from, state) do
    cond do
      # We have in-flight capacity - dispatch immediately
      map_size(state.in_flight_signals) < state.max_in_flight ->
        new_state = dispatch_signal(state, signal_log_id, signal)
        {:reply, :ok, new_state}

      # In-flight full, but pending has room - queue it
      map_size(state.pending_signals) < state.max_pending ->
        new_pending = Map.put(state.pending_signals, signal_log_id, signal)
        {:reply, :ok, %{state | pending_signals: new_pending}}

      # Both full - reject with backpressure
      true ->
        Telemetry.execute(
          [:jido, :signal, :subscription, :backpressure],
          %{},
          %{
            subscription_id: state.id,
            in_flight: map_size(state.in_flight_signals),
            pending: map_size(state.pending_signals)
          }
        )

        {:reply, {:error, :queue_full}, state}
    end
  end

  @impl GenServer
  def handle_call(_req, _from, state) do
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast({:ack, signal_log_id}, state) when is_binary(signal_log_id) do
    # Remove the acknowledged signal from in-flight
    new_in_flight = Map.delete(state.in_flight_signals, signal_log_id)

    # Extract timestamp from UUID7 for checkpoint comparison
    timestamp = ID.extract_timestamp(signal_log_id)

    # Update checkpoint if this is a higher number
    new_checkpoint = max(state.checkpoint, timestamp)

    # Persist checkpoint if journal adapter is configured
    persist_checkpoint(state, new_checkpoint)

    # Update state
    new_state = %{state | in_flight_signals: new_in_flight, checkpoint: new_checkpoint}

    # Process any pending signals
    new_state = process_pending_signals(new_state)

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_cast({:reconnect, new_client_pid}, state) do
    # Only proceed if the new client is alive
    if Process.alive?(new_client_pid) do
      # Monitor the new client process
      Process.monitor(new_client_pid)

      # Update the bus subscription to point to the new client PID
      updated_subscription = %{
        state.bus_subscription
        | dispatch: {:pid, target: new_client_pid, delivery_mode: :async}
      }

      # Update state with new client PID and subscription
      new_state = %{state | client_pid: new_client_pid, bus_subscription: updated_subscription}

      # Replay any signals that were missed while disconnected
      new_state = replay_missed_signals(new_state)

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:signal, {signal_log_id, signal}}, state) do
    cond do
      # We have in-flight capacity - dispatch immediately
      map_size(state.in_flight_signals) < state.max_in_flight ->
        new_state = dispatch_signal(state, signal_log_id, signal)
        {:noreply, new_state}

      # In-flight full, but pending has room - queue it
      map_size(state.pending_signals) < state.max_pending ->
        new_pending = Map.put(state.pending_signals, signal_log_id, signal)
        {:noreply, %{state | pending_signals: new_pending}}

      # Both full - drop the signal with backpressure telemetry
      true ->
        Telemetry.execute(
          [:jido, :signal, :subscription, :backpressure],
          %{},
          %{
            subscription_id: state.id,
            in_flight: map_size(state.in_flight_signals),
            pending: map_size(state.pending_signals)
          }
        )

        Logger.warning("Dropping signal #{signal_log_id} - subscription #{state.id} queue full")

        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{client_pid: client_pid} = state)
      when pid == client_pid do
    # Client disconnected, but we keep the subscription alive
    # The client can reconnect later using the reconnect/2 function
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:retry_pending, state) do
    # Clear the timer ref since we're handling it now
    state = %{state | retry_timer_ref: nil}

    # Process pending signals that need retry
    new_state = process_pending_for_retry(state)

    {:noreply, new_state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Helper function to replay missed signals
  defp replay_missed_signals(state) do
    Logger.debug("Replaying missed signals for subscription #{state.id}")

    # Get the bus state to access the log
    bus_state = :sys.get_state(state.bus_pid)

    missed_signals =
      Enum.filter(bus_state.log, fn {signal_log_id, signal} ->
        signal_after_checkpoint?(signal_log_id, signal, state.checkpoint)
      end)

    Enum.each(missed_signals, fn {signal_log_id, signal} ->
      replay_single_signal(signal_log_id, signal, state)
    end)

    state
  end

  defp signal_after_checkpoint?(signal_log_id, signal, checkpoint) do
    signal_timestamp_ms(signal_log_id, signal) > checkpoint
  end

  defp replay_single_signal(signal_log_id, signal, state) do
    if signal_after_checkpoint?(signal_log_id, signal, state.checkpoint) do
      dispatch_replay_signal(signal, state)
    end
  end

  defp signal_timestamp_ms(signal_log_id, signal) do
    case safe_extract_timestamp(signal_log_id) do
      {:ok, ts} ->
        ts

      :error ->
        case DateTime.from_iso8601(signal.time) do
          {:ok, timestamp, _offset} -> DateTime.to_unix(timestamp, :millisecond)
          _ -> 0
        end
    end
  end

  defp safe_extract_timestamp(signal_log_id) when is_binary(signal_log_id) do
    {:ok, ID.extract_timestamp(signal_log_id)}
  rescue
    _ -> :error
  end

  defp safe_extract_timestamp(_), do: :error

  defp dispatch_replay_signal(signal, state) do
    case Dispatch.dispatch(signal, state.bus_subscription.dispatch,
           task_supervisor: state.task_supervisor
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug(
          "Dispatch failed during replay, signal: #{inspect(signal)}, reason: #{inspect(reason)}"
        )
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Use state.id as the subscription_id since that's what we're using to identify the subscription
    if state.bus_pid do
      # Best effort to unsubscribe
      Bus.unsubscribe(state.bus_pid, state.id)
    end

    :ok
  end

  # Private Helpers

  # Persists checkpoint to journal if adapter is configured
  @spec persist_checkpoint(t(), non_neg_integer()) :: :ok
  defp persist_checkpoint(%{journal_adapter: nil}, _checkpoint), do: :ok

  defp persist_checkpoint(state, checkpoint) do
    case state.journal_adapter.put_checkpoint(state.checkpoint_key, checkpoint, state.journal_pid) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to persist checkpoint for #{state.checkpoint_key}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # Helper function to process pending signals if we have capacity
  # Only processes signals that haven't failed yet (no attempt count)
  @spec process_pending_signals(t()) :: t()
  defp process_pending_signals(state) do
    # Check if we have pending signals and space in the in-flight queue
    available_capacity = state.max_in_flight - map_size(state.in_flight_signals)

    # Find pending signals that haven't failed yet (no attempt count)
    new_pending_signals =
      Enum.filter(state.pending_signals, fn {id, _signal} ->
        not Map.has_key?(state.attempts, id)
      end)
      |> Map.new()

    if available_capacity > 0 && map_size(new_pending_signals) > 0 do
      # Get the first pending signal (using Enum.at to get the first key-value pair)
      {signal_id, signal} =
        new_pending_signals
        |> Enum.sort_by(fn {id, _} -> id end)
        |> List.first()

      # Remove from pending before dispatching
      new_pending = Map.delete(state.pending_signals, signal_id)
      state = %{state | pending_signals: new_pending}

      # Dispatch the signal using the configured dispatch mechanism
      new_state = dispatch_signal(state, signal_id, signal)

      # Recursively process more pending signals if available
      process_pending_signals(new_state)
    else
      # No change needed
      state
    end
  end

  # Process pending signals that are awaiting retry (have attempt counts)
  @spec process_pending_for_retry(t()) :: t()
  defp process_pending_for_retry(state) do
    # Find all pending signals that have attempt counts (i.e., failed signals)
    retry_signals =
      Enum.filter(state.pending_signals, fn {id, _signal} ->
        Map.has_key?(state.attempts, id)
      end)

    Enum.reduce(retry_signals, state, fn {signal_id, signal}, acc_state ->
      # Only process if we have in-flight capacity
      if map_size(acc_state.in_flight_signals) < acc_state.max_in_flight do
        # Remove from pending before dispatching
        new_pending = Map.delete(acc_state.pending_signals, signal_id)
        acc_state = %{acc_state | pending_signals: new_pending}

        # Dispatch the signal (this will handle success, failure, or DLQ)
        dispatch_signal(acc_state, signal_id, signal)
      else
        # No capacity, stop processing
        acc_state
      end
    end)
  end

  # Dispatches a signal and handles success/failure with retry tracking
  @spec dispatch_signal(t(), String.t(), term()) :: t()
  defp dispatch_signal(state, signal_log_id, signal) do
    if state.bus_subscription.dispatch do
      result =
        Dispatch.dispatch(signal, state.bus_subscription.dispatch,
          task_supervisor: state.task_supervisor
        )

      handle_dispatch_result(result, state, signal_log_id, signal)
    else
      # No dispatch configured - just add to in-flight
      new_in_flight = Map.put(state.in_flight_signals, signal_log_id, signal)
      %{state | in_flight_signals: new_in_flight}
    end
  end

  defp handle_dispatch_result(:ok, state, signal_log_id, signal) do
    # Success - clear attempts for this signal and add to in-flight
    new_attempts = Map.delete(state.attempts, signal_log_id)
    new_in_flight = Map.put(state.in_flight_signals, signal_log_id, signal)
    %{state | in_flight_signals: new_in_flight, attempts: new_attempts}
  end

  defp handle_dispatch_result({:error, reason}, state, signal_log_id, signal) do
    # Failure - increment attempts
    current_attempts = Map.get(state.attempts, signal_log_id, 0) + 1

    if current_attempts >= state.max_attempts do
      # Move to DLQ
      handle_dlq(state, signal_log_id, signal, reason, current_attempts)
    else
      handle_dispatch_retry(state, signal_log_id, signal, current_attempts)
    end
  end

  defp handle_dispatch_retry(state, signal_log_id, signal, current_attempts) do
    # Keep for retry - add to pending for later retry, update attempts
    Telemetry.execute(
      [:jido, :signal, :subscription, :dispatch, :retry],
      %{attempt: current_attempts},
      %{subscription_id: state.id, signal_id: signal.id}
    )

    new_attempts = Map.put(state.attempts, signal_log_id, current_attempts)
    new_pending = Map.put(state.pending_signals, signal_log_id, signal)
    state = %{state | pending_signals: new_pending, attempts: new_attempts}
    schedule_retry(state)
  end

  # Schedules a retry timer if one is not already scheduled
  @spec schedule_retry(t()) :: t()
  defp schedule_retry(%{retry_timer_ref: nil} = state) do
    timer_ref = Process.send_after(self(), :retry_pending, state.retry_interval)
    %{state | retry_timer_ref: timer_ref}
  end

  defp schedule_retry(state) do
    # Timer already scheduled
    state
  end

  # Handles moving a signal to the Dead Letter Queue after max attempts
  @spec handle_dlq(t(), String.t(), term(), term(), non_neg_integer()) :: t()
  defp handle_dlq(state, signal_log_id, signal, reason, attempt_count) do
    metadata = %{
      attempt_count: attempt_count,
      last_error: inspect(reason),
      subscription_id: state.id,
      signal_log_id: signal_log_id
    }

    if state.journal_adapter do
      case state.journal_adapter.put_dlq_entry(
             state.id,
             signal,
             reason,
             metadata,
             state.journal_pid
           ) do
        {:ok, dlq_id} ->
          Telemetry.execute(
            [:jido, :signal, :subscription, :dlq],
            %{},
            %{
              subscription_id: state.id,
              signal_id: signal.id,
              dlq_id: dlq_id,
              attempts: attempt_count
            }
          )

          Logger.debug("Signal #{signal.id} moved to DLQ after #{attempt_count} attempts")

        {:error, dlq_error} ->
          Logger.error("Failed to write to DLQ for signal #{signal.id}: #{inspect(dlq_error)}")
      end
    else
      Logger.warning(
        "Signal #{signal.id} exhausted #{attempt_count} attempts but no DLQ configured"
      )
    end

    # Remove from tracking - signal is now in DLQ (or dropped if no DLQ)
    new_in_flight = Map.delete(state.in_flight_signals, signal_log_id)
    new_pending = Map.delete(state.pending_signals, signal_log_id)
    new_attempts = Map.delete(state.attempts, signal_log_id)

    %{
      state
      | in_flight_signals: new_in_flight,
        pending_signals: new_pending,
        attempts: new_attempts
    }
  end
end
