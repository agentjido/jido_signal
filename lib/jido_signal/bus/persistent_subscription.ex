defmodule Jido.Signal.Bus.PersistentSubscription do
  @moduledoc """
  A GenServer that manages persistent subscription state and checkpoints for a single subscriber.

  This module maintains the subscription state for a client, tracking which signals have been
  acknowledged and allowing clients to resume from their last checkpoint after disconnection.
  Each instance maps 1:1 to a bus subscriber and is managed as a child of the Bus's dynamic supervisor.
  """
  use GenServer

  alias Jido.Signal.Context
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
              bus_name: Zoi.any() |> Zoi.optional(),
              bus_pid: Zoi.pid(),
              bus_subscription: Zoi.any(),
              client_pid: Zoi.pid() |> Zoi.nullable() |> Zoi.optional(),
              checkpoint: Zoi.default(Zoi.integer(), 0) |> Zoi.optional(),
              max_in_flight: Zoi.default(Zoi.integer(), 1000) |> Zoi.optional(),
              max_pending: Zoi.default(Zoi.integer(), 10_000) |> Zoi.optional(),
              dispatch_tasks: Zoi.default(Zoi.map(), %{}) |> Zoi.optional(),
              in_flight_signals: Zoi.default(Zoi.map(), %{}) |> Zoi.optional(),
              pending_signals: Zoi.default(Zoi.map(), %{}) |> Zoi.optional(),
              pending_order: Zoi.default(Zoi.any(), :queue.new()) |> Zoi.optional(),
              retry_pending_order: Zoi.default(Zoi.any(), :queue.new()) |> Zoi.optional(),
              acked_signals: Zoi.default(Zoi.map(), %{}) |> Zoi.optional(),
              dlq_pending: Zoi.default(Zoi.map(), %{}) |> Zoi.optional(),
              dlq_pending_order: Zoi.default(Zoi.any(), :queue.new()) |> Zoi.optional(),
              max_dlq_pending: Zoi.default(Zoi.integer(), 10_000) |> Zoi.optional(),
              dlq_retry_max_ms: Zoi.default(Zoi.integer(), 30_000) |> Zoi.optional(),
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

        GenServer.start_link(__MODULE__, opts,
          name: via_tuple(bus_name, id, Context.jido_opts(opts))
        )

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
          bus_name: bus_name,
          bus_pid: Keyword.fetch!(opts, :bus_pid),
          bus_subscription: bus_subscription,
          client_pid: Keyword.get(opts, :client_pid),
          checkpoint: initial_checkpoint,
          max_in_flight: Keyword.get(opts, :max_in_flight, 1000),
          max_pending: Keyword.get(opts, :max_pending, 10_000),
          max_dlq_pending: Keyword.get(opts, :max_dlq_pending, 10_000),
          dlq_retry_max_ms: Keyword.get(opts, :dlq_retry_max_ms, 30_000),
          max_attempts: Keyword.get(opts, :max_attempts, 5),
          retry_interval: Keyword.get(opts, :retry_interval, 100),
          dispatch_tasks: %{},
          in_flight_signals: %{},
          pending_signals: %{},
          pending_order: :queue.new(),
          retry_pending_order: :queue.new(),
          pending_batches: [],
          work_pending?: false,
          acked_signals: %{},
          dlq_pending: %{},
          dlq_pending_order: :queue.new(),
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
  def handle_call({:ack, ack_identifier}, _from, state) do
    case do_ack(state, ack_identifier) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
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
  def handle_call({:signal_batch, signal_batch}, _from, state) when is_list(signal_batch) do
    {next_state, dropped_count} = accept_signal_batch(state, signal_batch)
    next_state = process_pending_signals(next_state)
    batch_result = if dropped_count > 0, do: {:error, :queue_full}, else: :ok
    {:reply, batch_result, next_state}
  end

  @impl GenServer
  def handle_call(_req, _from, state) do
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast({:ack, ack_identifier}, state) do
    case do_ack(state, ack_identifier) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, error} ->
        Logger.warning("Ignoring invalid ack for subscription #{state.id}: #{inspect(error)}")
        {:noreply, state}
    end
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

    new_state =
      state
      |> process_dlq_pending()
      |> process_pending_for_retry()

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
    available_capacity = max(state.max_in_flight - in_flight_load(state), 0)
    dispatch_from_pending_queue(state, available_capacity)
  end

  # Process pending signals that are awaiting retry (have attempt counts)
  @spec process_pending_for_retry(t()) :: t()
  defp process_pending_for_retry(state) do
    available_capacity = max(state.max_in_flight - in_flight_load(state), 0)
    dispatch_from_retry_queue(state, available_capacity)
  end

  defp dispatch_from_pending_queue(state, capacity) when capacity <= 0, do: state

  defp dispatch_from_pending_queue(state, capacity) do
    case :queue.out(state.pending_order) do
      {{:value, signal_id}, next_order} ->
        case Map.pop(state.pending_signals, signal_id) do
          {nil, next_pending} ->
            dispatch_from_pending_queue(
              %{state | pending_order: next_order, pending_signals: next_pending},
              capacity
            )

          {signal, next_pending} ->
            next_state =
              state
              |> Map.put(:pending_order, next_order)
              |> Map.put(:pending_signals, next_pending)
              |> start_dispatch_signal(signal_log_id: signal_id, signal: signal)

            dispatch_from_pending_queue(next_state, capacity - 1)
        end

      {:empty, _} ->
        state
    end
  end

  defp dispatch_from_retry_queue(state, capacity) when capacity <= 0, do: state

  defp dispatch_from_retry_queue(state, capacity) do
    case :queue.out(state.retry_pending_order) do
      {{:value, signal_id}, next_order} ->
        case Map.pop(state.pending_signals, signal_id) do
          {nil, next_pending} ->
            dispatch_from_retry_queue(
              %{state | retry_pending_order: next_order, pending_signals: next_pending},
              capacity
            )

          {signal, next_pending} ->
            next_state =
              state
              |> Map.put(:retry_pending_order, next_order)
              |> Map.put(:pending_signals, next_pending)
              |> start_dispatch_signal(signal_log_id: signal_id, signal: signal)

            dispatch_from_retry_queue(next_state, capacity - 1)
        end

      {:empty, _} ->
        state
    end
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
    state = %{state | attempts: new_attempts}
    state = enqueue_retry_signal(state, signal_log_id, signal)
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
    case persist_to_dlq(state, signal_log_id, signal, reason, attempt_count) do
      {:ok, _dlq_id} ->
        clear_signal_tracking(state, signal_log_id)

      {:error, dlq_error} ->
        Logger.error(
          "Failed to write to DLQ for signal #{signal.id}, retaining for retry: #{inspect(dlq_error)}"
        )

        state
        |> move_signal_to_dlq_pending(signal_log_id, signal, reason, attempt_count, dlq_error)
        |> schedule_retry()
    end
  end

  defp maybe_monitor_client(state, nil), do: state

  defp maybe_monitor_client(state, client_pid) do
    if state.client_monitor_ref do
      Process.demonitor(state.client_monitor_ref, [:flush])
    end

    ref = Process.monitor(client_pid)
    %{state | client_monitor_ref: ref}
  end

  defp do_ack(state, []), do: {:ok, process_pending_signals(state)}

  defp do_ack(state, ack_identifiers) when is_list(ack_identifiers) do
    case validate_ack_ids(state, ack_identifiers) do
      {:ok, []} ->
        {:ok, process_pending_signals(state)}

      {:ok, resolved_entries} ->
        state =
          Enum.reduce(resolved_entries, state, fn {signal_log_id, _checkpoint_value}, acc ->
            ack_signal(acc, signal_log_id)
          end)

        highest_checkpoint =
          resolved_entries
          |> Enum.map(fn {_signal_log_id, checkpoint_value} -> checkpoint_value end)
          |> Enum.max()

        new_checkpoint = max(state.checkpoint, highest_checkpoint)
        persist_checkpoint(state, new_checkpoint)

        state =
          state
          |> Map.put(:checkpoint, new_checkpoint)
          |> process_pending_signals()

        {:ok, state}

      {:error, _} = error ->
        error
    end
  end

  defp do_ack(state, ack_identifier) do
    case resolve_ack_identifier(state, ack_identifier) do
      {:ok, {signal_log_id, checkpoint_value}} ->
        state = ack_signal(state, signal_log_id)
        new_checkpoint = max(state.checkpoint, checkpoint_value)
        persist_checkpoint(state, new_checkpoint)

        state =
          state
          |> Map.put(:checkpoint, new_checkpoint)
          |> process_pending_signals()

        {:ok, state}

      {:error, _} = error ->
        error
    end
  end

  defp validate_ack_ids(state, ack_identifiers) when is_list(ack_identifiers) do
    Enum.reduce_while(ack_identifiers, {:ok, []}, fn ack_identifier, {:ok, resolved_entries} ->
      case resolve_ack_identifier(state, ack_identifier) do
        {:ok, {_, _} = resolved_entry} -> {:cont, {:ok, [resolved_entry | resolved_entries]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp resolve_ack_identifier(state, ack_identifier) do
    case resolve_ack_log_id(state, ack_identifier) do
      {:ok, signal_log_id} ->
        case checkpoint_value(signal_log_id) do
          {:ok, value} ->
            {:ok, {signal_log_id, value}}

          {:error, _} = error ->
            error
        end

      {:error, _} = error ->
        error
    end
  end

  defp resolve_ack_log_id(state, ack_identifier) do
    if tracked_log_id?(state, ack_identifier) do
      {:ok, ack_identifier}
    else
      case find_log_id_by_signal_id(state, ack_identifier) do
        {:ok, signal_log_id} ->
          {:ok, signal_log_id}

        :error ->
          resolve_unknown_ack(ack_identifier)
      end
    end
  end

  defp tracked_log_id?(state, signal_log_id) do
    Map.has_key?(state.in_flight_signals, signal_log_id) or
      Map.has_key?(state.pending_signals, signal_log_id) or
      Map.has_key?(state.acked_signals, signal_log_id) or
      Map.has_key?(state.attempts, signal_log_id) or
      Map.has_key?(state.dlq_pending, signal_log_id) or
      dispatch_in_progress?(state, signal_log_id)
  end

  defp find_log_id_by_signal_id(state, signal_id) do
    with :error <- find_signal_log_id_in_signals(state.in_flight_signals, signal_id),
         :error <- find_signal_log_id_in_signals(state.pending_signals, signal_id),
         :error <- find_signal_log_id_in_dispatch_tasks(state.dispatch_tasks, signal_id) do
      find_signal_log_id_in_dlq_pending(state.dlq_pending, signal_id)
    end
  end

  defp find_signal_log_id_in_signals(signals_map, signal_id) when is_map(signals_map) do
    Enum.find_value(signals_map, :error, fn {signal_log_id, signal} ->
      if signal_id_matches?(signal, signal_id), do: {:ok, signal_log_id}, else: nil
    end)
  end

  defp find_signal_log_id_in_dispatch_tasks(dispatch_tasks, signal_id)
       when is_map(dispatch_tasks) do
    Enum.find_value(dispatch_tasks, :error, fn {_ref, {_task, signal_log_id, signal}} ->
      if signal_id_matches?(signal, signal_id), do: {:ok, signal_log_id}, else: nil
    end)
  end

  defp find_signal_log_id_in_dlq_pending(dlq_pending, signal_id) when is_map(dlq_pending) do
    Enum.find_value(dlq_pending, :error, fn {signal_log_id, entry} ->
      if signal_id_matches?(Map.get(entry, :signal), signal_id),
        do: {:ok, signal_log_id},
        else: nil
    end)
  end

  defp signal_id_matches?(%Jido.Signal{id: id}, signal_id), do: id == signal_id
  defp signal_id_matches?(_, _), do: false

  defp resolve_unknown_ack(ack_identifier)
       when is_binary(ack_identifier) or
              (is_integer(ack_identifier) and ack_identifier >= 0),
       do: invalid_ack_error(ack_identifier, :unknown_signal_log_id)

  defp resolve_unknown_ack(ack_identifier),
    do: invalid_ack_error(ack_identifier, :invalid_signal_log_id)

  defp checkpoint_value(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp checkpoint_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 ->
        {:ok, parsed}

      _ ->
        {:ok, ID.extract_timestamp(value)}
    end
  rescue
    _ -> invalid_ack_error(value, :invalid_signal_log_id)
  end

  defp checkpoint_value(value), do: invalid_ack_error(value, :invalid_signal_log_id)

  defp invalid_ack_error(value, reason) do
    {:error,
     Error.validation_error("invalid ack argument", %{
       field: :signal_log_id,
       value: value,
       reason: reason
     })}
  end

  defp accept_signal(state, signal_log_id, signal) do
    cond do
      in_flight_load(state) < state.max_in_flight ->
        {:ok, start_dispatch_signal(state, signal_log_id: signal_log_id, signal: signal)}

      map_size(state.pending_signals) < state.max_pending ->
        {:ok, enqueue_pending_signal(state, signal_log_id, signal)}

      true ->
        emit_backpressure(state)
        {:error, :queue_full, state}
    end
  end

  defp enqueue_pending_signal(state, signal_log_id, signal) do
    %{
      state
      | pending_signals: Map.put(state.pending_signals, signal_log_id, signal),
        pending_order: :queue.in(signal_log_id, state.pending_order)
    }
  end

  defp enqueue_retry_signal(state, signal_log_id, signal) do
    %{
      state
      | pending_signals: Map.put(state.pending_signals, signal_log_id, signal),
        retry_pending_order: :queue.in(signal_log_id, state.retry_pending_order)
    }
  end

  defp start_dispatch_signal(state, signal_log_id: signal_log_id, signal: signal) do
    signal = attach_bus_metadata(signal, state, signal_log_id)

    if state.bus_subscription.dispatch do
      case Dispatch.dispatch_async(
             signal,
             state.bus_subscription.dispatch,
             Context.jido_opts(state)
           ) do
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

  defp attach_bus_metadata(%Jido.Signal{} = signal, state, signal_log_id) do
    bus_metadata = %{
      log_id: signal_log_id,
      bus_name: state.bus_name,
      subscription_id: state.id
    }

    existing_extensions = Map.get(signal, :extensions, %{})
    existing_bus_metadata = Map.get(existing_extensions, "bus", %{})
    merged_bus_metadata = Map.merge(existing_bus_metadata, bus_metadata)
    %{signal | extensions: Map.put(existing_extensions, "bus", merged_bus_metadata)}
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
    Enum.reduce(signal_batch, {state, 0}, fn entry, {acc_state, dropped_count} ->
      accept_signal_entry(acc_state, dropped_count, entry)
    end)
  end

  defp accept_signal_entry(acc_state, dropped_count, {signal_log_id, signal}) do
    case accept_signal(acc_state, signal_log_id, signal) do
      {:ok, new_state} ->
        {new_state, dropped_count}

      {:error, :queue_full, new_state} ->
        {new_state, dropped_count + 1}
    end
  end

  defp accept_signal_entry(acc_state, dropped_count, _entry) do
    {acc_state, dropped_count + 1}
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

  defp clear_signal_tracking(state, signal_log_id) do
    %{
      state
      | in_flight_signals: Map.delete(state.in_flight_signals, signal_log_id),
        pending_signals: Map.delete(state.pending_signals, signal_log_id),
        acked_signals: Map.delete(state.acked_signals, signal_log_id),
        dlq_pending: Map.delete(state.dlq_pending, signal_log_id),
        attempts: Map.delete(state.attempts, signal_log_id)
    }
    |> maybe_compact_dlq_pending_order()
  end

  defp ensure_dlq_pending_capacity(state, incoming_signal_log_id) do
    cond do
      Map.has_key?(state.dlq_pending, incoming_signal_log_id) ->
        state

      map_size(state.dlq_pending) < state.max_dlq_pending ->
        state

      true ->
        drop_oldest_dlq_pending(state)
    end
  end

  defp drop_oldest_dlq_pending(state) do
    case :queue.out(state.dlq_pending_order) do
      {{:value, signal_log_id}, next_order} ->
        if Map.has_key?(state.dlq_pending, signal_log_id) do
          Logger.warning(
            "Dropping oldest pending DLQ retry for subscription #{state.id}: #{inspect(signal_log_id)}"
          )

          %{
            state
            | dlq_pending: Map.delete(state.dlq_pending, signal_log_id),
              dlq_pending_order: next_order
          }
        else
          drop_oldest_dlq_pending(%{state | dlq_pending_order: next_order})
        end

      {:empty, next_order} ->
        %{state | dlq_pending_order: next_order}
    end
  end

  defp maybe_compact_dlq_pending_order(state) do
    if :queue.len(state.dlq_pending_order) > state.max_dlq_pending * 2 do
      rebuilt_order =
        state.dlq_pending
        |> Map.keys()
        |> :queue.from_list()

      %{state | dlq_pending_order: rebuilt_order}
    else
      state
    end
  end

  defp ack_signal(state, signal_log_id) do
    ack_marker? = dispatch_in_progress?(state, signal_log_id)

    updated_acked_signals =
      if ack_marker? do
        Map.put(state.acked_signals, signal_log_id, true)
      else
        Map.delete(state.acked_signals, signal_log_id)
      end

    %{
      state
      | in_flight_signals: Map.delete(state.in_flight_signals, signal_log_id),
        pending_signals: Map.delete(state.pending_signals, signal_log_id),
        attempts: Map.delete(state.attempts, signal_log_id),
        dlq_pending: Map.delete(state.dlq_pending, signal_log_id),
        acked_signals: updated_acked_signals
    }
  end

  defp dispatch_in_progress?(state, signal_log_id) do
    Enum.any?(state.dispatch_tasks, fn {_ref, {_task, dispatch_signal_log_id, _signal}} ->
      dispatch_signal_log_id == signal_log_id
    end)
  end

  defp move_signal_to_dlq_pending(
         state,
         signal_log_id,
         signal,
         reason,
         attempt_count,
         dlq_error
       ) do
    base_state = clear_signal_tracking(state, signal_log_id)
    base_state = ensure_dlq_pending_capacity(base_state, signal_log_id)
    existing_entry = Map.get(base_state.dlq_pending, signal_log_id, %{})
    next_failures = Map.get(existing_entry, :dlq_failures, 0) + 1

    dlq_entry = %{
      signal: signal,
      reason: reason,
      attempt_count: attempt_count,
      dlq_failures: next_failures,
      last_error: dlq_error,
      next_retry_at: next_dlq_retry_at(base_state, next_failures)
    }

    next_dlq_order =
      if Map.has_key?(base_state.dlq_pending, signal_log_id) do
        base_state.dlq_pending_order
      else
        :queue.in(signal_log_id, base_state.dlq_pending_order)
      end

    %{
      base_state
      | dlq_pending: Map.put(base_state.dlq_pending, signal_log_id, dlq_entry),
        dlq_pending_order: next_dlq_order
    }
  end

  defp process_dlq_pending(%{dlq_pending: dlq_pending} = state) when map_size(dlq_pending) == 0,
    do: state

  defp process_dlq_pending(state) do
    now_ms = System.monotonic_time(:millisecond)

    state =
      Enum.reduce(state.dlq_pending, state, fn {signal_log_id, dlq_entry}, acc_state ->
        if retry_due?(dlq_entry, now_ms) do
          retry_dlq_write(acc_state, signal_log_id, dlq_entry)
        else
          acc_state
        end
      end)

    if map_size(state.dlq_pending) > 0 do
      schedule_retry(state)
    else
      state
    end
  end

  defp retry_dlq_write(state, signal_log_id, dlq_entry) do
    case persist_to_dlq(
           state,
           signal_log_id,
           dlq_entry.signal,
           dlq_entry.reason,
           dlq_entry.attempt_count
         ) do
      {:ok, _dlq_id} ->
        clear_signal_tracking(state, signal_log_id)

      {:error, dlq_error} ->
        next_failures = Map.get(dlq_entry, :dlq_failures, 0) + 1

        updated_entry = %{
          dlq_entry
          | dlq_failures: next_failures,
            last_error: dlq_error,
            next_retry_at: next_dlq_retry_at(state, next_failures)
        }

        %{state | dlq_pending: Map.put(state.dlq_pending, signal_log_id, updated_entry)}
    end
  end

  defp retry_due?(dlq_entry, now_ms) do
    Map.get(dlq_entry, :next_retry_at, 0) <= now_ms
  end

  defp next_dlq_retry_at(state, failure_count) do
    System.monotonic_time(:millisecond) + dlq_retry_delay_ms(state, failure_count)
  end

  defp dlq_retry_delay_ms(state, failure_count) do
    base = max(state.retry_interval, 1)
    max_delay = max(state.dlq_retry_max_ms, base)
    exponential = trunc(base * :math.pow(2, max(failure_count - 1, 0)))
    capped = min(exponential, max_delay)
    jitter = :rand.uniform(max(div(capped, 2), 1))
    min(capped + jitter, max_delay)
  end

  defp persist_to_dlq(_state, signal_log_id, _signal, _reason, _attempt_count)
       when not is_binary(signal_log_id) do
    {:error, :invalid_signal_log_id}
  end

  defp persist_to_dlq(%{journal_adapter: nil}, _signal_log_id, _signal, _reason, _attempt_count) do
    {:error, :no_journal_adapter}
  end

  defp persist_to_dlq(state, signal_log_id, signal, reason, attempt_count) do
    metadata = %{
      attempt_count: attempt_count,
      last_error: inspect(reason),
      subscription_id: state.id,
      signal_log_id: signal_log_id
    }

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
        {:ok, dlq_id}

      {:error, dlq_error} ->
        {:error, dlq_error}
    end
  catch
    :exit, exit_reason ->
      {:error, {:adapter_exit, exit_reason}}
  end
end
