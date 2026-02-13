defmodule Jido.Signal.Bus do
  @moduledoc """
  Implements a signal bus for routing, filtering, and distributing signals.

  The Bus acts as a central hub for signals in the system, allowing components
  to publish and subscribe to signals. It handles routing based on signal paths,
  subscription management, persistence, and signal filtering. The Bus maintains
  an internal log of signals and provides mechanisms for retrieving historical
  signals and snapshots.

  ## Journal Configuration

  The Bus can be configured with a journal adapter for persistent checkpoints.
  This allows subscriptions to resume from their last acknowledged position
  after restarts.

  ### Via start_link

      {:ok, bus} = Bus.start_link(
        name: :my_bus,
        journal_adapter: Jido.Signal.Journal.Adapters.ETS,
        journal_adapter_opts: []
      )

  ### Via Application Config

      # In config/config.exs
      config :jido_signal,
        journal_adapter: Jido.Signal.Journal.Adapters.ETS,
        journal_adapter_opts: []

  ### Available Adapters

    * `Jido.Signal.Journal.Adapters.ETS` - ETS-based persistence (default for production)
    * `Jido.Signal.Journal.Adapters.InMemory` - In-memory persistence (for testing)
    * `Jido.Signal.Journal.Adapters.Mnesia` - Mnesia-based persistence (for distributed systems)

  If no adapter is configured, checkpoints will be in-memory only and will not
  survive process restarts.
  """

  use GenServer

  alias Jido.Signal.Bus.MiddlewarePipeline
  alias Jido.Signal.Bus.Partition
  alias Jido.Signal.Bus.PartitionSupervisor
  alias Jido.Signal.Bus.Snapshot
  alias Jido.Signal.Bus.State, as: BusState
  alias Jido.Signal.Bus.Stream
  alias Jido.Signal.Bus.Subscriber
  alias Jido.Signal.Dispatch
  alias Jido.Signal.Error
  alias Jido.Signal.ID
  alias Jido.Signal.Router
  alias Jido.Signal.Telemetry

  require Logger

  @type start_option ::
          {:name, atom()}
          | {atom(), term()}

  @type server ::
          pid() | atom() | binary() | {name :: atom() | binary(), registry :: module()}
  @type path :: Router.path()
  @type subscription_id :: String.t()

  @doc """
  Returns a child specification for starting the bus under a supervisor.

  ## Options

  - name: The name to register the bus under (required)
  - router: A custom router implementation (optional)
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  @doc """
  Starts a new bus process.

  ## Options

    * `:name` - The name to register the bus under (required)
    * `:router` - A custom router implementation (optional)
    * `:middleware` - A list of {module, opts} tuples for middleware (optional)
    * `:middleware_timeout_ms` - Timeout for middleware execution in ms (default: 100)
    * `:journal_adapter` - Module implementing `Jido.Signal.Journal.Persistence` (optional)
    * `:journal_adapter_opts` - Options to pass to journal adapter init (optional, unused by default adapters)
    * `:journal_pid` - Pre-initialized journal adapter pid (optional, skips adapter init if provided)
    * `:max_log_size` - Maximum number of signals to keep in the log (default: 100_000)
    * `:log_ttl_ms` - Optional TTL in milliseconds for log entries; enables periodic garbage collection (default: nil)

  If `:journal_adapter` is not specified, falls back to application config
  (`:jido_signal, :journal_adapter`).
  """
  @impl GenServer
  def init({name, opts}) do
    Process.flag(:trap_exit, true)

    {:ok, child_supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    {journal_adapter, journal_pid} = init_journal_adapter(name, opts)
    middleware_specs = Keyword.get(opts, :middleware, [])

    case MiddlewarePipeline.init_middleware(middleware_specs) do
      {:ok, middleware_configs} ->
        init_state(name, opts, child_supervisor, journal_adapter, journal_pid, middleware_configs)

      {:error, reason} ->
        {:stop, {:middleware_init_failed, reason}}
    end
  end

  # Initializes the journal adapter from opts or application config
  defp init_journal_adapter(name, opts) do
    journal_adapter =
      Keyword.get(opts, :journal_adapter) ||
        Application.get_env(:jido_signal, :journal_adapter)

    existing_journal_pid = Keyword.get(opts, :journal_pid)

    do_init_journal_adapter(name, journal_adapter, existing_journal_pid)
  end

  defp do_init_journal_adapter(_name, journal_adapter, existing_pid)
       when not is_nil(journal_adapter) and not is_nil(existing_pid) do
    {journal_adapter, existing_pid}
  end

  defp do_init_journal_adapter(_name, journal_adapter, _existing_pid)
       when not is_nil(journal_adapter) do
    case journal_adapter.init() do
      :ok ->
        {journal_adapter, nil}

      {:ok, pid} ->
        {journal_adapter, pid}

      {:error, reason} ->
        Logger.warning(
          "Failed to initialize journal adapter #{inspect(journal_adapter)}: #{inspect(reason)}"
        )

        {nil, nil}
    end
  end

  defp do_init_journal_adapter(name, _journal_adapter, _existing_pid) do
    Logger.debug(
      "Bus #{name} started without journal adapter - checkpoints will be in-memory only"
    )

    {nil, nil}
  end

  # Initializes the bus state with all configuration
  defp init_state(name, opts, child_supervisor, journal_adapter, journal_pid, middleware_configs) do
    middleware_timeout_ms = Keyword.get(opts, :middleware_timeout_ms, 100)
    partition_count = Keyword.get(opts, :partition_count, 1)
    max_log_size = Keyword.get(opts, :max_log_size, 100_000)
    log_ttl_ms = Keyword.get(opts, :log_ttl_ms)

    partition_pids =
      init_partitions(
        name,
        opts,
        partition_count,
        middleware_configs,
        middleware_timeout_ms,
        journal_adapter,
        journal_pid
      )

    schedule_gc_if_needed(log_ttl_ms)

    state = %BusState{
      name: name,
      jido: Keyword.get(opts, :jido),
      router: Keyword.get(opts, :router, Router.new!()),
      child_supervisor: child_supervisor,
      middleware: middleware_configs,
      middleware_timeout_ms: middleware_timeout_ms,
      journal_adapter: journal_adapter,
      journal_pid: journal_pid,
      partition_count: partition_count,
      partition_pids: partition_pids,
      max_log_size: max_log_size,
      log_ttl_ms: log_ttl_ms
    }

    {:ok, state}
  end

  defp init_partitions(_name, _opts, partition_count, _middleware, _timeout, _adapter, _pid)
       when partition_count <= 1 do
    []
  end

  defp init_partitions(
         name,
         opts,
         partition_count,
         middleware_configs,
         middleware_timeout_ms,
         journal_adapter,
         journal_pid
       ) do
    partition_opts = [
      partition_count: partition_count,
      bus_name: name,
      bus_pid: self(),
      jido: Keyword.get(opts, :jido),
      middleware: middleware_configs,
      middleware_timeout_ms: middleware_timeout_ms,
      journal_adapter: journal_adapter,
      journal_pid: journal_pid,
      rate_limit_per_sec: Keyword.get(opts, :partition_rate_limit_per_sec, 10_000),
      burst_size: Keyword.get(opts, :partition_burst_size, 1_000)
    ]

    {:ok, _sup_pid} = PartitionSupervisor.start_link(partition_opts)

    0..(partition_count - 1)
    |> Enum.map(&GenServer.whereis(Partition.via_tuple(name, &1, partition_opts)))
    |> Enum.reject(&is_nil/1)
  end

  defp schedule_gc_if_needed(nil), do: :ok
  defp schedule_gc_if_needed(log_ttl_ms), do: Process.send_after(self(), :gc_log, log_ttl_ms)

  @doc """
  Starts a new bus process and links it to the calling process.

  ## Options

    * `:name` - The name to register the bus under (required)
    * `:router` - A custom router implementation (optional)
    * `:middleware` - A list of {module, opts} tuples for middleware (optional)
    * `:middleware_timeout_ms` - Timeout for middleware execution in ms (default: 100)
    * `:journal_adapter` - Module implementing `Jido.Signal.Journal.Persistence` (optional)
    * `:journal_adapter_opts` - Options to pass to journal adapter init (optional)
    * `:journal_pid` - Pre-initialized journal adapter pid (optional, skips adapter init if provided)

  ## Returns

    * `{:ok, pid}` if the bus starts successfully
    * `{:error, reason}` if the bus fails to start

  ## Examples

      iex> {:ok, pid} = Jido.Signal.Bus.start_link(name: :my_bus)
      iex> is_pid(pid)
      true

      iex> {:ok, pid} = Jido.Signal.Bus.start_link([
      ...>   name: :my_bus,
      ...>   journal_adapter: Jido.Signal.Journal.Adapters.ETS
      ...> ])
      iex> is_pid(pid)
      true
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, {name, opts}, name: via_tuple(name, opts))
  end

  defdelegate via_tuple(name, opts \\ []), to: Jido.Signal.Util
  defdelegate whereis(server, opts \\ []), to: Jido.Signal.Util

  @doc """
  Subscribes to signals matching the given path pattern.
  Options:
  - dispatch: How to dispatch signals to the subscriber (default: async to calling process)
  - persistent: Whether the subscription should persist across restarts (default: false)
  """
  @spec subscribe(server(), path(), Keyword.t()) :: {:ok, subscription_id()} | {:error, term()}
  def subscribe(bus, path, opts \\ []) do
    # Ensure we have a dispatch configuration
    opts =
      if Keyword.has_key?(opts, :dispatch) do
        # Ensure dispatch has delivery_mode: :async
        dispatch = Keyword.get(opts, :dispatch)

        dispatch =
          case dispatch do
            {:pid, pid_opts} ->
              {:pid, Keyword.put(pid_opts, :delivery_mode, :async)}

            other ->
              other
          end

        Keyword.put(opts, :dispatch, dispatch)
      else
        Keyword.put(opts, :dispatch, {:pid, target: self(), delivery_mode: :async})
      end

    with {:ok, pid} <- whereis(bus) do
      GenServer.call(pid, {:subscribe, path, opts})
    end
  end

  @doc """
  Unsubscribes from signals using the subscription ID.
  Options:
  - delete_persistence: Whether to delete persistent subscription data (default: false)
  """
  @spec unsubscribe(server(), subscription_id(), Keyword.t()) :: :ok | {:error, term()}
  def unsubscribe(bus, subscription_id, opts \\ []) do
    with {:ok, pid} <- whereis(bus) do
      GenServer.call(pid, {:unsubscribe, subscription_id, opts})
    end
  end

  @doc """
  Publishes a list of signals to the bus.
  Returns {:ok, recorded_signals} on success.
  """
  @spec publish(server(), [Jido.Signal.t()]) ::
          {:ok, [Jido.Signal.Bus.RecordedSignal.t()]} | {:error, term()}
  def publish(_bus, []) do
    {:ok, []}
  end

  def publish(bus, signals) when is_list(signals) do
    with {:ok, pid} <- whereis(bus) do
      GenServer.call(pid, {:publish, signals})
    end
  end

  @doc """
  Replays signals from the bus log that match the given path pattern.
  Optional start_timestamp to replay from a specific point in time.
  """
  @spec replay(server(), path(), non_neg_integer(), Keyword.t()) ::
          {:ok, [Jido.Signal.Bus.RecordedSignal.t()]} | {:error, term()}
  def replay(bus, path \\ "*", start_timestamp \\ 0, opts \\ []) do
    with {:ok, pid} <- whereis(bus) do
      GenServer.call(pid, {:replay, path, start_timestamp, opts})
    end
  end

  @doc """
  Creates a new snapshot of signals matching the given path pattern.
  """
  @spec snapshot_create(server(), path()) :: {:ok, Snapshot.SnapshotRef.t()} | {:error, term()}
  def snapshot_create(bus, path) do
    with {:ok, pid} <- whereis(bus) do
      GenServer.call(pid, {:snapshot_create, path})
    end
  end

  @doc """
  Lists all available snapshots.
  """
  @spec snapshot_list(server()) :: [Snapshot.SnapshotRef.t()]
  def snapshot_list(bus) do
    with {:ok, pid} <- whereis(bus) do
      GenServer.call(pid, :snapshot_list)
    end
  end

  @doc """
  Reads a snapshot by its ID.
  """
  @spec snapshot_read(server(), String.t()) :: {:ok, Snapshot.SnapshotData.t()} | {:error, term()}
  def snapshot_read(bus, snapshot_id) do
    with {:ok, pid} <- whereis(bus) do
      GenServer.call(pid, {:snapshot_read, snapshot_id})
    end
  end

  @doc """
  Deletes a snapshot by its ID.
  """
  @spec snapshot_delete(server(), String.t()) :: :ok | {:error, term()}
  def snapshot_delete(bus, snapshot_id) do
    with {:ok, pid} <- whereis(bus) do
      GenServer.call(pid, {:snapshot_delete, snapshot_id})
    end
  end

  @doc """
  Acknowledges a signal for a persistent subscription.
  """
  @spec ack(server(), subscription_id(), String.t() | integer()) :: :ok | {:error, term()}
  def ack(bus, subscription_id, signal_id) do
    with {:ok, pid} <- whereis(bus) do
      GenServer.call(pid, {:ack, subscription_id, signal_id})
    end
  end

  @doc """
  Reconnects a client to a persistent subscription.
  """
  @spec reconnect(server(), subscription_id(), pid()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def reconnect(bus, subscription_id, client_pid) do
    with {:ok, pid} <- whereis(bus) do
      GenServer.call(pid, {:reconnect, subscription_id, client_pid})
    end
  end

  @doc """
  Lists all DLQ entries for a subscription.

  ## Parameters
  - bus: The bus server reference
  - subscription_id: The ID of the subscription

  ## Returns
  - `{:ok, [dlq_entry]}` - List of DLQ entries
  - `{:error, term()}` - If the operation fails
  """
  @spec dlq_entries(server(), subscription_id()) :: {:ok, [map()]} | {:error, term()}
  def dlq_entries(bus, subscription_id) do
    with {:ok, pid} <- whereis(bus) do
      GenServer.call(pid, {:dlq_entries, subscription_id})
    end
  end

  @doc """
  Replays DLQ entries for a subscription, attempting redelivery.

  ## Options
  - `:limit` - Maximum entries to replay (default: all)
  - `:clear_on_success` - Remove from DLQ if delivery succeeds (default: true)

  ## Returns
  - `{:ok, %{succeeded: integer(), failed: integer()}}` - Results of replay
  - `{:error, term()}` - If the operation fails
  """
  @spec redrive_dlq(server(), subscription_id(), keyword()) ::
          {:ok, %{succeeded: integer(), failed: integer()}} | {:error, term()}
  def redrive_dlq(bus, subscription_id, opts \\ []) do
    with {:ok, pid} <- whereis(bus) do
      GenServer.call(pid, {:redrive_dlq, subscription_id, opts})
    end
  end

  @doc """
  Clears all DLQ entries for a subscription.

  ## Returns
  - `:ok` - DLQ cleared
  - `{:error, term()}` - If the operation fails
  """
  @spec clear_dlq(server(), subscription_id()) :: :ok | {:error, term()}
  def clear_dlq(bus, subscription_id) do
    with {:ok, pid} <- whereis(bus) do
      GenServer.call(pid, {:clear_dlq, subscription_id})
    end
  end

  @impl GenServer
  def handle_call({:subscribe, path, opts}, _from, state) do
    subscription_id = Keyword.get(opts, :subscription_id, ID.generate!())
    opts = Keyword.put(opts, :subscription_id, subscription_id)

    case Subscriber.subscribe(state, subscription_id, path, opts) do
      {:ok, new_state} ->
        sync_subscription_to_partition(new_state, subscription_id, state)
        {:reply, {:ok, subscription_id}, new_state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:unsubscribe, subscription_id, opts}, _from, state) do
    if not Enum.empty?(state.partition_pids) do
      partition_id = Partition.partition_for(subscription_id, state.partition_count)
      partition_pid = Enum.at(state.partition_pids, partition_id)

      if partition_pid do
        GenServer.call(partition_pid, {:remove_subscription, subscription_id})
      end
    end

    case Subscriber.unsubscribe(state, subscription_id, opts) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:publish, signals}, _from, state) do
    context = %{
      bus_name: state.name,
      timestamp: DateTime.utc_now(),
      metadata: %{}
    }

    result =
      with {:ok, processed_signals, updated_middleware} <-
             MiddlewarePipeline.before_publish(
               state.middleware,
               signals,
               context,
               state.middleware_timeout_ms
             ),
           state_with_middleware = %{state | middleware: updated_middleware},
           {:ok, new_state, uuid_signal_pairs} <-
             publish_with_middleware(
               state_with_middleware,
               processed_signals,
               context,
               state.middleware_timeout_ms
             ) do
        final_state = finalize_publish(new_state, processed_signals, context)
        recorded_signals = build_recorded_signals(uuid_signal_pairs)
        {:ok, recorded_signals, final_state}
      end

    case result do
      {:ok, recorded_signals, final_state} -> {:reply, {:ok, recorded_signals}, final_state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:replay, path, start_timestamp, opts}, _from, state) do
    case Stream.filter(state, path, start_timestamp, opts) do
      {:ok, signals} -> {:reply, {:ok, signals}, state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:snapshot_create, path}, _from, state) do
    case Snapshot.create(state, path) do
      {:ok, snapshot_ref, new_state} -> {:reply, {:ok, snapshot_ref}, new_state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call(:snapshot_list, _from, state) do
    {:reply, Snapshot.list(state), state}
  end

  def handle_call({:snapshot_read, snapshot_id}, _from, state) do
    case Snapshot.read(state, snapshot_id) do
      {:ok, snapshot_data} -> {:reply, {:ok, snapshot_data}, state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:snapshot_delete, snapshot_id}, _from, state) do
    case Snapshot.delete(state, snapshot_id) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:ack, subscription_id, signal_id}, _from, state) do
    # Check if the subscription exists
    subscription = BusState.get_subscription(state, subscription_id)

    cond do
      # If subscription doesn't exist, return error
      is_nil(subscription) ->
        {:reply,
         {:error,
          Error.validation_error(
            "Subscription does not exist",
            %{field: :subscription_id, value: subscription_id}
          )}, state}

      # If subscription is not persistent, return error
      not subscription.persistent? ->
        {:reply,
         {:error,
          Error.validation_error(
            "Subscription is not persistent",
            %{field: :subscription_id, value: subscription_id}
          )}, state}

      # Otherwise, acknowledge the signal by forwarding to PersistentSubscription
      true ->
        if subscription.persistence_pid do
          GenServer.call(subscription.persistence_pid, {:ack, signal_id})
        end

        {:reply, :ok, state}
    end
  end

  def handle_call({:reconnect, subscriber_id, client_pid}, _from, state) do
    case BusState.get_subscription(state, subscriber_id) do
      nil ->
        {:reply, {:error, :subscription_not_found}, state}

      subscription ->
        do_reconnect(state, subscriber_id, client_pid, subscription)
    end
  end

  def handle_call({:dlq_entries, subscription_id}, _from, state) do
    if state.journal_adapter do
      result = state.journal_adapter.get_dlq_entries(subscription_id, state.journal_pid)
      {:reply, result, state}
    else
      {:reply, {:error, :no_journal_adapter}, state}
    end
  end

  def handle_call({:redrive_dlq, _subscription_id, _opts}, _from, %{journal_adapter: nil} = state) do
    {:reply, {:error, :no_journal_adapter}, state}
  end

  def handle_call({:redrive_dlq, subscription_id, opts}, _from, state) do
    result = do_redrive_dlq(state, subscription_id, opts)
    {:reply, result, state}
  end

  def handle_call({:clear_dlq, subscription_id}, _from, state) do
    if state.journal_adapter do
      result = state.journal_adapter.clear_dlq(subscription_id, state.journal_pid)
      {:reply, result, state}
    else
      {:reply, {:error, :no_journal_adapter}, state}
    end
  end

  # Private helpers for handle_call callbacks

  defp sync_subscription_to_partition(_new_state, _subscription_id, %{partition_pids: []}),
    do: :ok

  defp sync_subscription_to_partition(new_state, subscription_id, state) do
    subscription = BusState.get_subscription(new_state, subscription_id)
    partition_id = Partition.partition_for(subscription_id, state.partition_count)
    partition_pid = Enum.at(state.partition_pids, partition_id)

    if partition_pid do
      GenServer.call(partition_pid, {:add_subscription, subscription_id, subscription})
    end
  end

  defp finalize_publish(new_state, processed_signals, context) do
    final_middleware =
      MiddlewarePipeline.after_publish(
        new_state.middleware,
        processed_signals,
        context,
        new_state.middleware_timeout_ms
      )

    %{new_state | middleware: final_middleware}
  end

  defp build_recorded_signals(uuid_signal_pairs) do
    Enum.map(uuid_signal_pairs, fn {uuid, signal} ->
      %Jido.Signal.Bus.RecordedSignal{
        id: uuid,
        type: signal.type,
        created_at: DateTime.utc_now(),
        signal: signal
      }
    end)
  end

  defp do_reconnect(state, subscriber_id, client_pid, %{persistent?: true} = subscription) do
    updated_subscription = update_subscription_dispatch(subscription, client_pid)
    {final_state, latest_timestamp} = apply_reconnect(state, subscriber_id, updated_subscription)
    GenServer.cast(subscription.persistence_pid, {:reconnect, client_pid})
    {:reply, {:ok, latest_timestamp}, final_state}
  end

  defp do_reconnect(state, subscriber_id, client_pid, subscription) do
    updated_subscription = update_subscription_dispatch(subscription, client_pid)
    {final_state, latest_timestamp} = apply_reconnect(state, subscriber_id, updated_subscription)
    {:reply, {:ok, latest_timestamp}, final_state}
  end

  defp update_subscription_dispatch(subscription, client_pid) do
    %{subscription | dispatch: {:pid, [delivery_mode: :async, target: client_pid]}}
  end

  defp apply_reconnect(state, subscriber_id, updated_subscription) do
    case BusState.add_subscription(state, subscriber_id, updated_subscription) do
      {:error, :subscription_exists} ->
        {state, get_latest_log_timestamp(state)}

      {:ok, updated_state} ->
        {updated_state, get_latest_log_timestamp(updated_state)}
    end
  end

  defp get_latest_log_timestamp(state) do
    state.log
    |> Map.values()
    |> Enum.map(& &1.time)
    |> Enum.max(fn -> 0 end)
  end

  defp do_redrive_dlq(state, subscription_id, opts) do
    limit = Keyword.get(opts, :limit, :infinity)
    clear_on_success = Keyword.get(opts, :clear_on_success, true)

    with {:ok, entries} <-
           state.journal_adapter.get_dlq_entries(subscription_id, state.journal_pid),
         {:ok, subscription} <- fetch_subscription(state, subscription_id) do
      entries_to_process = limit_entries(entries, limit)
      result = process_dlq_entries(state, entries_to_process, subscription, clear_on_success)
      emit_redrive_telemetry(state.name, subscription_id, result)
      {:ok, result}
    end
  end

  defp fetch_subscription(state, subscription_id) do
    case BusState.get_subscription(state, subscription_id) do
      nil -> {:error, :subscription_not_found}
      subscription -> {:ok, subscription}
    end
  end

  defp limit_entries(entries, :infinity), do: entries
  defp limit_entries(entries, limit), do: Enum.take(entries, limit)

  defp process_dlq_entries(state, entries, subscription, clear_on_success) do
    results = Enum.map(entries, &redrive_single_entry(state, &1, subscription, clear_on_success))
    succeeded = Enum.count(results, &(&1 == :ok))
    %{succeeded: succeeded, failed: length(results) - succeeded}
  end

  defp redrive_single_entry(state, entry, subscription, clear_on_success) do
    case Dispatch.dispatch(entry.signal, subscription.dispatch) do
      :ok ->
        if clear_on_success,
          do: state.journal_adapter.delete_dlq_entry(entry.id, state.journal_pid)

        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp emit_redrive_telemetry(bus_name, subscription_id, %{succeeded: succeeded, failed: failed}) do
    Telemetry.execute(
      [:jido, :signal, :bus, :dlq, :redrive],
      %{succeeded: succeeded, failed: failed},
      %{bus_name: bus_name, subscription_id: subscription_id}
    )
  end

  # Private helper function to publish signals with middleware dispatch hooks
  # Accumulates middleware state changes across all dispatches
  # Also collects dispatch results for backpressure detection
  defp publish_with_middleware(state, signals, context, timeout_ms) do
    with :ok <- validate_signals(signals),
         {:ok, new_state, uuid_signal_pairs} <- BusState.append_signals(state, signals) do
      if Enum.empty?(state.partition_pids) do
        publish_without_partitions(new_state, signals, uuid_signal_pairs, context, timeout_ms)
      else
        publish_with_partitions(new_state, signals, uuid_signal_pairs, context)
      end
    end
  end

  # Partitioned dispatch - cast to all partitions for async dispatch
  # For persistent subscriptions, we still need to handle backpressure from the main bus
  defp publish_with_partitions(state, signals, uuid_signal_pairs, context) do
    signal_log_id_map = Map.new(uuid_signal_pairs, fn {uuid, sig} -> {sig.id, uuid} end)
    persistent_results = dispatch_to_persistent_subscriptions(state, signals, signal_log_id_map)

    case find_saturated_subscriptions(persistent_results) do
      [] ->
        broadcast_to_partitions(state.partition_pids, signals, uuid_signal_pairs, context)
        {:ok, state, uuid_signal_pairs}

      [{subscription_id, _} | _] = saturated ->
        emit_backpressure_telemetry(state.name, saturated)

        {:error,
         Error.execution_error("Subscription saturated", %{
           subscription_id: subscription_id,
           reason: :queue_full
         })}
    end
  end

  defp dispatch_to_persistent_subscriptions(state, signals, signal_log_id_map) do
    Enum.flat_map(signals, &dispatch_signal_to_persistent(state, &1, signal_log_id_map))
  end

  defp dispatch_signal_to_persistent(state, signal, signal_log_id_map) do
    state.subscriptions
    |> Enum.filter(fn {_id, sub} -> sub.persistent? && Router.matches?(signal.type, sub.path) end)
    |> Enum.map(fn {subscription_id, subscription} ->
      {subscription_id, dispatch_to_subscription(signal, subscription, signal_log_id_map)}
    end)
  end

  defp find_saturated_subscriptions(results) do
    Enum.filter(results, fn
      {_id, {:error, :queue_full}} -> true
      _ -> false
    end)
  end

  defp broadcast_to_partitions(partition_pids, signals, uuid_signal_pairs, context) do
    Enum.each(partition_pids, fn partition_pid ->
      GenServer.cast(partition_pid, {:dispatch, signals, uuid_signal_pairs, context})
    end)
  end

  defp emit_backpressure_telemetry(bus_name, saturated) do
    Telemetry.execute(
      [:jido, :signal, :bus, :backpressure],
      %{saturated_count: length(saturated)},
      %{bus_name: bus_name}
    )
  end

  # Original non-partitioned dispatch with full middleware support
  defp publish_without_partitions(new_state, signals, uuid_signal_pairs, context, timeout_ms) do
    signal_log_id_map = Map.new(uuid_signal_pairs, fn {uuid, signal} -> {signal.id, uuid} end)

    dispatch_ctx = %{
      state: new_state,
      context: context,
      timeout_ms: timeout_ms,
      signal_log_id_map: signal_log_id_map
    }

    {final_middleware, dispatch_results} =
      Enum.reduce(signals, {new_state.middleware, []}, fn signal, acc ->
        dispatch_signal_to_subscriptions(signal, new_state.subscriptions, acc, dispatch_ctx)
      end)

    case find_saturated_subscriptions(dispatch_results) do
      [] ->
        {:ok, %{new_state | middleware: final_middleware}, uuid_signal_pairs}

      [{subscription_id, _} | _] = saturated ->
        emit_backpressure_telemetry(new_state.name, saturated)

        {:error,
         Error.execution_error("Subscription saturated", %{
           subscription_id: subscription_id,
           reason: :queue_full
         })}
    end
  end

  defp dispatch_signal_to_subscriptions(signal, subscriptions, acc, dispatch_ctx) do
    Enum.reduce(subscriptions, acc, fn {subscription_id, subscription},
                                       {acc_middleware, acc_results} ->
      if Router.matches?(signal.type, subscription.path) do
        dispatch_matching_signal(
          signal,
          subscription_id,
          subscription,
          acc_middleware,
          acc_results,
          dispatch_ctx
        )
      else
        {acc_middleware, acc_results}
      end
    end)
  end

  defp dispatch_matching_signal(
         signal,
         subscription_id,
         subscription,
         acc_middleware,
         acc_results,
         dispatch_ctx
       ) do
    emit_before_dispatch_telemetry(dispatch_ctx.state.name, signal, subscription_id, subscription)

    middleware_result =
      MiddlewarePipeline.before_dispatch(
        acc_middleware,
        signal,
        subscription,
        dispatch_ctx.context,
        dispatch_ctx.timeout_ms
      )

    handle_middleware_result(
      middleware_result,
      signal,
      subscription_id,
      subscription,
      acc_middleware,
      acc_results,
      dispatch_ctx
    )
  end

  defp handle_middleware_result(
         {:ok, processed_signal, updated_middleware},
         _signal,
         subscription_id,
         subscription,
         _acc_middleware,
         acc_results,
         dispatch_ctx
       ) do
    result =
      dispatch_to_subscription(processed_signal, subscription, dispatch_ctx.signal_log_id_map)

    emit_after_dispatch_telemetry(
      dispatch_ctx.state.name,
      processed_signal,
      subscription_id,
      subscription,
      result
    )

    new_middleware =
      MiddlewarePipeline.after_dispatch(
        updated_middleware,
        processed_signal,
        subscription,
        result,
        dispatch_ctx.context,
        dispatch_ctx.timeout_ms
      )

    {new_middleware, [{subscription_id, result} | acc_results]}
  end

  defp handle_middleware_result(
         :skip,
         signal,
         subscription_id,
         subscription,
         acc_middleware,
         acc_results,
         dispatch_ctx
       ) do
    emit_dispatch_skipped_telemetry(
      dispatch_ctx.state.name,
      signal,
      subscription_id,
      subscription
    )

    {acc_middleware, acc_results}
  end

  defp handle_middleware_result(
         {:error, reason},
         signal,
         subscription_id,
         subscription,
         acc_middleware,
         acc_results,
         dispatch_ctx
       ) do
    emit_dispatch_error_telemetry(
      dispatch_ctx.state.name,
      signal,
      subscription_id,
      subscription,
      reason
    )

    Logger.warning("Middleware halted dispatch for signal #{signal.id}: #{inspect(reason)}")
    {acc_middleware, acc_results}
  end

  defp emit_before_dispatch_telemetry(bus_name, signal, subscription_id, subscription) do
    Telemetry.execute(
      [:jido, :signal, :bus, :before_dispatch],
      %{timestamp: System.monotonic_time(:microsecond)},
      %{
        bus_name: bus_name,
        signal_id: signal.id,
        signal_type: signal.type,
        subscription_id: subscription_id,
        subscription_path: subscription.path,
        signal: signal,
        subscription: subscription
      }
    )
  end

  defp emit_after_dispatch_telemetry(bus_name, signal, subscription_id, subscription, result) do
    Telemetry.execute(
      [:jido, :signal, :bus, :after_dispatch],
      %{timestamp: System.monotonic_time(:microsecond)},
      %{
        bus_name: bus_name,
        signal_id: signal.id,
        signal_type: signal.type,
        subscription_id: subscription_id,
        subscription_path: subscription.path,
        dispatch_result: result,
        signal: signal,
        subscription: subscription
      }
    )
  end

  defp emit_dispatch_skipped_telemetry(bus_name, signal, subscription_id, subscription) do
    Telemetry.execute(
      [:jido, :signal, :bus, :dispatch_skipped],
      %{timestamp: System.monotonic_time(:microsecond)},
      %{
        bus_name: bus_name,
        signal_id: signal.id,
        signal_type: signal.type,
        subscription_id: subscription_id,
        subscription_path: subscription.path,
        reason: :middleware_skip,
        signal: signal,
        subscription: subscription
      }
    )
  end

  defp emit_dispatch_error_telemetry(bus_name, signal, subscription_id, subscription, reason) do
    Telemetry.execute(
      [:jido, :signal, :bus, :dispatch_error],
      %{timestamp: System.monotonic_time(:microsecond)},
      %{
        bus_name: bus_name,
        signal_id: signal.id,
        signal_type: signal.type,
        subscription_id: subscription_id,
        subscription_path: subscription.path,
        error: reason,
        signal: signal,
        subscription: subscription
      }
    )
  end

  # Dispatch signal to a subscription
  # For persistent subscriptions, use synchronous call to get backpressure feedback
  # For regular subscriptions, use normal async dispatch
  defp dispatch_to_subscription(signal, subscription, signal_log_id_map) do
    if subscription.persistent? && subscription.persistence_pid do
      # For persistent subscriptions, call synchronously to get backpressure feedback
      signal_log_id = Map.get(signal_log_id_map, signal.id)

      try do
        GenServer.call(subscription.persistence_pid, {:signal, {signal_log_id, signal}})
      catch
        :exit, {:noproc, _} ->
          {:error, :subscription_not_available}

        :exit, {:timeout, _} ->
          {:error, :timeout}
      end
    else
      # For regular subscriptions, use async dispatch
      Dispatch.dispatch(signal, subscription.dispatch)
    end
  end

  defp validate_signals(signals) do
    invalid_signals =
      Enum.reject(signals, fn signal ->
        is_struct(signal, Jido.Signal)
      end)

    case invalid_signals do
      [] -> :ok
      _ -> {:error, :invalid_signals}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # Remove the subscriber if it dies
    case Enum.find(state.subscribers, fn {_id, sub_pid} -> sub_pid == pid end) do
      nil ->
        {:noreply, state}

      {subscriber_id, _} ->
        Logger.info("Subscriber #{subscriber_id} terminated with reason: #{inspect(reason)}")
        {_, new_subscribers} = Map.pop(state.subscribers, subscriber_id)
        {:noreply, %{state | subscribers: new_subscribers}}
    end
  end

  def handle_info(:gc_log, %{log_ttl_ms: nil} = state), do: {:noreply, state}

  def handle_info(:gc_log, state) do
    Process.send_after(self(), :gc_log, state.log_ttl_ms)
    new_state = prune_expired_log_entries(state)
    {:noreply, new_state}
  end

  def handle_info(msg, state) do
    Logger.debug("Unexpected message in Bus: #{inspect(msg)}")
    {:noreply, state}
  end

  defp prune_expired_log_entries(state) do
    cutoff_time = DateTime.add(DateTime.utc_now(), -state.log_ttl_ms, :millisecond)
    original_size = map_size(state.log)

    new_log =
      state.log
      |> Enum.filter(&signal_not_expired?(&1, cutoff_time))
      |> Map.new()

    emit_gc_telemetry_if_pruned(state, original_size, new_log)
    %{state | log: new_log}
  end

  defp signal_not_expired?({_uuid, signal}, cutoff_time) do
    case DateTime.from_iso8601(signal.time) do
      {:ok, signal_time, _} -> DateTime.compare(signal_time, cutoff_time) != :lt
      _ -> true
    end
  end

  defp emit_gc_telemetry_if_pruned(state, original_size, new_log) do
    removed_count = original_size - map_size(new_log)

    if removed_count > 0 do
      Telemetry.execute(
        [:jido, :signal, :bus, :log_gc],
        %{removed_count: removed_count},
        %{bus_name: state.name, new_size: map_size(new_log), ttl_ms: state.log_ttl_ms}
      )
    end
  end
end
