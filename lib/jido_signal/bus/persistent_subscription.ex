defmodule Jido.Signal.Bus.PersistentSubscription do
  @moduledoc """
  A GenServer that manages persistent subscription state and checkpoints for a single subscriber.

  This module maintains the subscription state for a client, tracking which signals have been
  acknowledged and allowing clients to resume from their last checkpoint after disconnection.
  Each instance maps 1:1 to a bus subscriber and is managed as a child of the Bus's dynamic supervisor.
  """
  use GenServer

  alias Jido.Signal.Dispatch
  alias Jido.Signal.Error
  alias Jido.Signal.ID
  alias Jido.Signal.Names
  alias Jido.Signal.Telemetry
  alias Jido.Signal.Util

  require Logger

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              jido: Zoi.atom() |> Zoi.nullable() |> Zoi.optional(),
              bus_pid: Zoi.pid(),
              bus_subscription: Zoi.any(),
              client_pid: Zoi.pid() |> Zoi.nullable() |> Zoi.optional(),
              checkpoint: Zoi.default(Zoi.integer(), 0) |> Zoi.optional(),
              max_in_flight: Zoi.default(Zoi.integer(), 1000) |> Zoi.optional(),
              max_pending: Zoi.default(Zoi.integer(), 10_000) |> Zoi.optional(),
              dispatch_tasks: Zoi.default(Zoi.map(), %{}) |> Zoi.optional(),
              in_flight_signals: Zoi.default(Zoi.map(), %{}) |> Zoi.optional(),
              pending_signals: Zoi.default(Zoi.map(), %{}) |> Zoi.optional(),
              acked_signals: Zoi.default(Zoi.map(), %{}) |> Zoi.optional(),
              max_attempts: Zoi.default(Zoi.integer(), 5) |> Zoi.optional(),
              attempts: Zoi.default(Zoi.map(), %{}) |> Zoi.optional(),
              retry_interval: Zoi.default(Zoi.integer(), 100) |> Zoi.optional(),
              retry_timer_ref: Zoi.reference() |> Zoi.nullable() |> Zoi.optional(),
              pending_batches: Zoi.default(Zoi.list(), []) |> Zoi.optional(),
              work_pending?: Zoi.default(Zoi.boolean(), false) |> Zoi.optional(),
              client_monitor_ref: Zoi.reference() |> Zoi.nullable() |> Zoi.optional(),
              journal_adapter: Zoi.module() |> Zoi.nullable() |> Zoi.optional(),
              journal_pid: Zoi.pid() |> Zoi.nullable() |> Zoi.optional(),
              checkpoint_key: Zoi.string()
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
  - client_pid: PID of the client process (optional; nil means disconnected/offline)
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

    case validate_init_opts(opts) do
      :ok ->
        bus_name = Keyword.get(opts, :bus_name, :unknown)
        GenServer.start_link(__MODULE__, opts, name: via_tuple(bus_name, id, jido_opts(opts)))

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns a bus-scoped registry tuple for a persistent subscription process.
  """
  @spec via_tuple(atom(), String.t(), keyword()) :: {:via, Registry, {module(), tuple()}}
  def via_tuple(bus_name, id, opts \\ []) do
    {:via, Registry, {Names.registry(opts), {:persistent_subscription, bus_name, id}}}
  end

  @doc """
  Legacy lookup tuple helper retained for backwards compatibility.
  """
  @spec via_tuple(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via_tuple(id) do
    Util.via_tuple(id)
  end

  @doc """
  Resolves the persistent subscription pid by bus and subscription id.
  """
  @spec whereis(atom(), String.t(), keyword()) :: pid() | nil
  def whereis(bus_name, id, opts \\ []) do
    GenServer.whereis(via_tuple(bus_name, id, opts))
  end

  @doc """
  Legacy process lookup retained for backwards compatibility.
  """
  @spec whereis(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def whereis(id) do
    Util.whereis(id)
  end

  @impl GenServer
  def init(opts) do
    case validate_init_opts(opts) do
      :ok ->
        Process.flag(:trap_exit, true)

        # Extract the bus subscription
        bus_subscription = Keyword.fetch!(opts, :bus_subscription)

        id = Keyword.fetch!(opts, :id)
        journal_adapter = Keyword.get(opts, :journal_adapter)
        journal_pid = Keyword.get(opts, :journal_pid)
        bus_name = Keyword.get(opts, :bus_name, :unknown)
        initial_checkpoint = Keyword.get(opts, :checkpoint, 0)

        # Compute checkpoint key (unique per bus + subscription)
        checkpoint_key = "#{bus_name}:#{id}"

        state = %__MODULE__{
          id: id,
          jido: Keyword.get(opts, :jido),
          bus_pid: Keyword.fetch!(opts, :bus_pid),
          bus_subscription: bus_subscription,
          client_pid: Keyword.get(opts, :client_pid),
          checkpoint: initial_checkpoint,
          max_in_flight: Keyword.get(opts, :max_in_flight, 1000),
          max_pending: Keyword.get(opts, :max_pending, 10_000),
          max_attempts: Keyword.get(opts, :max_attempts, 5),
          retry_interval: Keyword.get(opts, :retry_interval, 100),
          dispatch_tasks: %{},
          in_flight_signals: %{},
          pending_signals: %{},
          pending_batches: [],
          work_pending?: false,
          acked_signals: %{},
          attempts: %{},
          journal_adapter: journal_adapter,
          journal_pid: journal_pid,
          checkpoint_key: checkpoint_key
        }

        state = maybe_monitor_client(state, state.client_pid)

        {:ok, state, {:continue, :load_checkpoint}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:ack, signal_log_id}, _from, state) when is_binary(signal_log_id) do
    {:reply, :ok, do_ack(state, signal_log_id)}
  end

  @impl GenServer
  def handle_call({:ack, signal_log_ids}, _from, state) when is_list(signal_log_ids) do
    {:reply, :ok, do_ack(state, signal_log_ids)}
  end

  @impl GenServer
  def handle_call({:ack, _invalid_arg}, _from, state) do
    {:reply,
     {:error, Error.validation_error("invalid ack argument", %{reason: :invalid_ack_argument})},
     state}
  end

  @impl GenServer
  def handle_call(:checkpoint, _from, state) do
    {:reply, state.checkpoint, state}
  end

  @impl GenServer
  def handle_call({:signal, {signal_log_id, signal}}, _from, state) do
    case accept_signal(state, signal_log_id, signal) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, :queue_full, new_state} ->
        {:reply, {:error, :queue_full}, new_state}
    end
  end

  @impl GenServer
  def handle_call(_req, _from, state) do
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast({:ack, signal_log_id}, state) when is_binary(signal_log_id) do
    {:noreply, do_ack(state, signal_log_id)}
  end

  @impl GenServer
  def handle_cast({:signal_batch, signal_batch, reply_to, publish_ref}, state)
      when is_list(signal_batch) and is_pid(reply_to) and is_reference(publish_ref) do
    state
    |> enqueue_batch(signal_batch, reply_to, publish_ref)
    |> noreply_with_work()
  end

  @impl GenServer
  def handle_cast({:reconnect, new_client_pid}, state) do
    handle_cast({:reconnect, new_client_pid, []}, state)
  end

  @impl GenServer
  def handle_cast({:reconnect, new_client_pid, missed_signals}, state)
      when is_list(missed_signals) do
    # Update the bus subscription to point to the new client PID
    updated_subscription = %{
      state.bus_subscription
      | dispatch: {:pid, target: new_client_pid, delivery_mode: :async}
    }

    # Update state with new client PID and subscription
    new_state = %{state | client_pid: new_client_pid, bus_subscription: updated_subscription}
    new_state = maybe_monitor_client(new_state, new_client_pid)
    replay_batch = normalize_replay_batch(missed_signals)

    new_state
    |> enqueue_batch(replay_batch, nil, nil)
    |> noreply_with_work()
  end

  @impl GenServer
  def handle_continue(:drain, state) do
    state = %{state | work_pending?: false}
    state = drain_pending_batches(state)
    {:noreply, process_pending_signals(state)}
  end

  @impl GenServer
  def handle_continue(:load_checkpoint, state) do
    loaded_checkpoint =
      load_checkpoint(
        state.journal_adapter,
        state.checkpoint_key,
        state.journal_pid,
        state.checkpoint
      )

    {:noreply, %{state | checkpoint: max(state.checkpoint, loaded_checkpoint)}}
  end

  @impl GenServer
  def handle_info({:signal, {signal_log_id, signal}}, state) do
    case accept_signal(state, signal_log_id, signal) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, :queue_full, new_state} ->
        Logger.warning("Dropping signal #{signal_log_id} - subscription #{state.id} queue full")
        {:noreply, new_state}
    end
  end

  @impl GenServer
  def handle_info({ref, dispatch_result}, state) when is_reference(ref) do
    case Map.pop(state.dispatch_tasks, ref) do
      {nil, _dispatch_tasks} ->
        {:noreply, state}

      {{_task, signal_log_id, signal}, dispatch_tasks} ->
        Process.demonitor(ref, [:flush])

        new_state =
          state
          |> Map.put(:dispatch_tasks, dispatch_tasks)
          |> handle_dispatch_result(dispatch_result, signal_log_id, signal)
          |> process_pending_signals()

        {:noreply, new_state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.pop(state.dispatch_tasks, ref) do
      {{_task, signal_log_id, signal}, dispatch_tasks} ->
        new_state =
          state
          |> Map.put(:dispatch_tasks, dispatch_tasks)
          |> handle_dispatch_result(
            {:error, {:dispatch_task_exit, reason}},
            signal_log_id,
            signal
          )
          |> process_pending_signals()

        {:noreply, new_state}

      {nil, _dispatch_tasks} ->
        handle_client_down(pid, state)
    end
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

  @impl GenServer
  def terminate(_reason, state) do
    if state.retry_timer_ref, do: Process.cancel_timer(state.retry_timer_ref)
    if state.client_monitor_ref, do: Process.demonitor(state.client_monitor_ref, [:flush])
    shutdown_dispatch_tasks(state.dispatch_tasks)

    :ok
  end

  # Private Helpers

  defp validate_init_opts(opts) do
    required = [:id, :bus_pid, :bus_subscription]

    case Enum.find(required, fn key -> not Keyword.has_key?(opts, key) end) do
      nil ->
        :ok

      missing_key ->
        {:error, {:missing_option, missing_key}}
    end
  end

  defp load_checkpoint(nil, _checkpoint_key, _journal_pid, default_checkpoint) do
    default_checkpoint
  end

  defp load_checkpoint(journal_adapter, checkpoint_key, journal_pid, default_checkpoint) do
    case journal_adapter.get_checkpoint(checkpoint_key, journal_pid) do
      {:ok, checkpoint} ->
        checkpoint

      {:error, :not_found} ->
        default_checkpoint

      {:error, reason} ->
        Logger.warning("Failed to load checkpoint for #{checkpoint_key}: #{inspect(reason)}")

        default_checkpoint
    end
  end

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
    available_capacity = state.max_in_flight - in_flight_load(state)

    if available_capacity <= 0 do
      state
    else
      state.pending_signals
      |> Enum.filter(fn {id, _signal} -> not Map.has_key?(state.attempts, id) end)
      |> Enum.sort_by(fn {id, _signal} -> id end)
      |> Enum.take(available_capacity)
      |> Enum.reduce(state, fn {signal_id, signal}, acc ->
        acc
        |> Map.update!(:pending_signals, &Map.delete(&1, signal_id))
        |> start_dispatch_signal(signal_log_id: signal_id, signal: signal)
      end)
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

    Enum.reduce_while(retry_signals, state, fn {signal_id, signal}, acc_state ->
      if in_flight_load(acc_state) < acc_state.max_in_flight do
        updated_state =
          acc_state
          |> Map.update!(:pending_signals, &Map.delete(&1, signal_id))
          |> start_dispatch_signal(signal_log_id: signal_id, signal: signal)

        {:cont, updated_state}
      else
        {:halt, acc_state}
      end
    end)
  end

  defp handle_dispatch_result(state, :ok, signal_log_id, signal) do
    # Success - clear attempts for this signal and add to in-flight
    new_attempts = Map.delete(state.attempts, signal_log_id)

    if Map.has_key?(state.acked_signals, signal_log_id) do
      %{
        state
        | attempts: new_attempts,
          acked_signals: Map.delete(state.acked_signals, signal_log_id)
      }
    else
      new_in_flight = Map.put(state.in_flight_signals, signal_log_id, signal)
      %{state | in_flight_signals: new_in_flight, attempts: new_attempts}
    end
  end

  defp handle_dispatch_result(state, {:error, reason}, signal_log_id, signal) do
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

    clear_signal_tracking(state, signal_log_id)
  end

  defp maybe_monitor_client(state, nil), do: state

  defp maybe_monitor_client(state, client_pid) do
    if state.client_monitor_ref do
      Process.demonitor(state.client_monitor_ref, [:flush])
    end

    ref = Process.monitor(client_pid)
    %{state | client_monitor_ref: ref}
  end

  defp do_ack(state, signal_log_id) when is_binary(signal_log_id) do
    new_in_flight = Map.delete(state.in_flight_signals, signal_log_id)
    new_acked = Map.put(state.acked_signals, signal_log_id, true)
    timestamp = ID.extract_timestamp(signal_log_id)
    new_checkpoint = max(state.checkpoint, timestamp)
    persist_checkpoint(state, new_checkpoint)

    state = %{
      state
      | in_flight_signals: new_in_flight,
        acked_signals: new_acked,
        checkpoint: new_checkpoint
    }

    process_pending_signals(state)
  end

  defp do_ack(state, []) do
    process_pending_signals(state)
  end

  defp do_ack(state, signal_log_ids) when is_list(signal_log_ids) do
    new_in_flight =
      Enum.reduce(signal_log_ids, state.in_flight_signals, fn id, acc ->
        Map.delete(acc, id)
      end)

    new_acked =
      Enum.reduce(signal_log_ids, state.acked_signals, fn id, acc ->
        Map.put(acc, id, true)
      end)

    highest_timestamp =
      signal_log_ids
      |> Enum.map(&ID.extract_timestamp/1)
      |> Enum.max()

    new_checkpoint = max(state.checkpoint, highest_timestamp)
    persist_checkpoint(state, new_checkpoint)

    state = %{
      state
      | in_flight_signals: new_in_flight,
        acked_signals: new_acked,
        checkpoint: new_checkpoint
    }

    process_pending_signals(state)
  end

  defp accept_signal(state, signal_log_id, signal) do
    cond do
      in_flight_load(state) < state.max_in_flight ->
        {:ok, start_dispatch_signal(state, signal_log_id: signal_log_id, signal: signal)}

      map_size(state.pending_signals) < state.max_pending ->
        new_pending = Map.put(state.pending_signals, signal_log_id, signal)
        {:ok, %{state | pending_signals: new_pending}}

      true ->
        emit_backpressure(state)
        {:error, :queue_full, state}
    end
  end

  defp start_dispatch_signal(state, signal_log_id: signal_log_id, signal: signal) do
    if state.bus_subscription.dispatch do
      case Dispatch.dispatch_async(signal, state.bus_subscription.dispatch, jido_opts(state)) do
        {:ok, task} ->
          dispatch_tasks = Map.put(state.dispatch_tasks, task.ref, {task, signal_log_id, signal})
          %{state | dispatch_tasks: dispatch_tasks}

        {:error, reason} ->
          handle_dispatch_result(state, {:error, reason}, signal_log_id, signal)
      end
    else
      new_in_flight = Map.put(state.in_flight_signals, signal_log_id, signal)
      %{state | in_flight_signals: new_in_flight}
    end
  end

  defp in_flight_load(state) do
    map_size(state.in_flight_signals) + map_size(state.dispatch_tasks)
  end

  defp emit_backpressure(state) do
    Telemetry.execute(
      [:jido, :signal, :subscription, :backpressure],
      %{},
      %{
        subscription_id: state.id,
        in_flight: in_flight_load(state),
        pending: map_size(state.pending_signals)
      }
    )
  end

  defp enqueue_batch(state, [], _reply_to, _publish_ref), do: state

  defp enqueue_batch(state, signal_batch, reply_to, publish_ref) do
    pending_batches = [{signal_batch, reply_to, publish_ref} | state.pending_batches]
    %{state | pending_batches: pending_batches}
  end

  defp drain_pending_batches(%{pending_batches: []} = state), do: state

  defp drain_pending_batches(state) do
    state
    |> Map.put(:pending_batches, [])
    |> drain_pending_batches(Enum.reverse(state.pending_batches))
  end

  defp drain_pending_batches(state, pending_batches) do
    Enum.reduce(pending_batches, state, fn {signal_batch, reply_to, publish_ref}, acc ->
      {next_state, dropped_count} = accept_signal_batch(acc, signal_batch)
      batch_result = if dropped_count > 0, do: {:error, :queue_full}, else: :ok
      maybe_send_batch_result(reply_to, publish_ref, batch_result)
      maybe_emit_bus_backpressure(next_state, publish_ref, dropped_count)
      next_state
    end)
  end

  defp accept_signal_batch(state, signal_batch) do
    Enum.reduce(signal_batch, {state, 0}, fn {signal_log_id, signal},
                                             {acc_state, dropped_count} ->
      case accept_signal(acc_state, signal_log_id, signal) do
        {:ok, new_state} ->
          {new_state, dropped_count}

        {:error, :queue_full, new_state} ->
          {new_state, dropped_count + 1}
      end
    end)
  end

  defp normalize_replay_batch(missed_signals) do
    Enum.flat_map(missed_signals, fn
      {signal_log_id, %Jido.Signal{} = signal} when is_binary(signal_log_id) ->
        [{signal_log_id, signal}]

      %Jido.Signal{} = signal ->
        [{ID.generate!(), signal}]

      _other ->
        []
    end)
  end

  defp maybe_send_batch_result(reply_to, publish_ref, batch_result)
       when is_pid(reply_to) and is_reference(publish_ref) do
    send(reply_to, {:persistent_enqueue_result, publish_ref, batch_result})
    :ok
  end

  defp maybe_send_batch_result(_reply_to, _publish_ref, _batch_result), do: :ok

  defp maybe_emit_bus_backpressure(state, publish_ref, dropped_count)
       when dropped_count > 0 and is_reference(publish_ref) do
    send(state.bus_pid, {:persistent_backpressure, state.id, publish_ref, dropped_count})
    :ok
  end

  defp maybe_emit_bus_backpressure(_state, _publish_ref, _dropped_count), do: :ok

  defp noreply_with_work(%{work_pending?: true} = state), do: {:noreply, state}

  defp noreply_with_work(state) do
    {:noreply, %{state | work_pending?: true}, {:continue, :drain}}
  end

  defp handle_client_down(pid, %{client_pid: client_pid} = state) when pid == client_pid do
    # Client disconnected, but we keep the subscription alive
    # The client can reconnect later using reconnect/2.
    {:noreply, state}
  end

  defp handle_client_down(_pid, state), do: {:noreply, state}

  defp shutdown_dispatch_tasks(dispatch_tasks) do
    Enum.each(dispatch_tasks, fn {_ref, {task, _signal_log_id, _signal}} ->
      Task.shutdown(task, :brutal_kill)
    end)
  end

  defp jido_opts(%{jido: nil}), do: []
  defp jido_opts(%{jido: instance}), do: [jido: instance]

  defp jido_opts(opts) when is_list(opts) do
    case Keyword.get(opts, :jido) do
      nil -> []
      instance -> [jido: instance]
    end
  end

  defp clear_signal_tracking(state, signal_log_id) do
    %{
      state
      | in_flight_signals: Map.delete(state.in_flight_signals, signal_log_id),
        pending_signals: Map.delete(state.pending_signals, signal_log_id),
        acked_signals: Map.delete(state.acked_signals, signal_log_id),
        attempts: Map.delete(state.attempts, signal_log_id)
    }
  end
end
