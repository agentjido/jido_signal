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

  alias Jido.Signal.Bus.DispatchPipeline
  alias Jido.Signal.Bus.MiddlewarePipeline
  alias Jido.Signal.Bus.Partition
  alias Jido.Signal.Bus.PersistentRef
  alias Jido.Signal.Bus.SignalValidation
  alias Jido.Signal.Bus.Snapshot
  alias Jido.Signal.Bus.State, as: BusState
  alias Jido.Signal.Bus.Stream
  alias Jido.Signal.Bus.Subscriber
  alias Jido.Signal.Bus.Supervisor, as: BusSupervisor
  alias Jido.Signal.Config
  alias Jido.Signal.Context
  alias Jido.Signal.Dispatch
  alias Jido.Signal.Error
  alias Jido.Signal.ID
  alias Jido.Signal.Names
  alias Jido.Signal.Retry
  alias Jido.Signal.Router
  alias Jido.Signal.Telemetry

  require Logger

  @persistent_enqueue_timeout_ms 50

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
      start: {BusSupervisor, :start_link, [opts]},
      type: :supervisor,
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

    with {journal_adapter, journal_pid, journal_owned?} <- init_journal_adapter(name, opts),
         middleware_specs = Keyword.get(opts, :middleware, []),
         {:ok, middleware_configs} <- MiddlewarePipeline.init_middleware(middleware_specs),
         {:ok, child_supervisor} <- resolve_child_supervisor(name, opts),
         {:ok, partition_supervisor} <- resolve_partition_supervisor(name, opts),
         :ok <-
           sync_partition_middleware(
             name,
             opts,
             partition_supervisor,
             Keyword.get(opts, :partition_count, 1),
             middleware_configs
           ) do
      init_state(
        name,
        opts,
        child_supervisor,
        partition_supervisor,
        journal_adapter,
        journal_pid,
        journal_owned?,
        middleware_configs
      )
    else
      {:error, reason} ->
        Logger.error("Bus #{name} initialization failed: #{inspect(reason)}")
        {:stop, {:bus_init_failed, reason}}
    end
  end

  # Initializes the journal adapter from opts or application config
  defp init_journal_adapter(name, opts) do
    journal_adapter =
      Keyword.get(opts, :journal_adapter) ||
        Config.get_env(:journal_adapter)

    existing_journal_pid = Keyword.get(opts, :journal_pid)

    case validate_journal_config(journal_adapter, existing_journal_pid) do
      :ok ->
        do_init_journal_adapter(name, journal_adapter, existing_journal_pid)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_journal_config(nil, journal_pid) when not is_nil(journal_pid) do
    {:error, :journal_pid_without_adapter}
  end

  defp validate_journal_config(_journal_adapter, _journal_pid), do: :ok

  defp resolve_child_supervisor(_name, opts) do
    resolve_named_process(
      Keyword.get(opts, :child_supervisor_name) || Keyword.get(opts, :child_supervisor)
    )
  end

  defp resolve_partition_supervisor(_name, opts) do
    partition_count = Keyword.get(opts, :partition_count, 1)

    if partition_count <= 1 do
      {:ok, nil}
    else
      resolve_named_process(
        Keyword.get(opts, :partition_supervisor_name) || Keyword.get(opts, :partition_supervisor)
      )
    end
  end

  defp resolve_named_process(pid) when is_pid(pid), do: {:ok, pid}

  defp resolve_named_process(nil), do: {:error, :runtime_supervisor_child_missing}

  defp resolve_named_process(name) do
    Retry.until(
      10,
      fn ->
        case GenServer.whereis(name) do
          nil -> :retry
          pid when is_pid(pid) -> {:ok, pid}
        end
      end,
      delay_ms: 10,
      factor: 1.0,
      on_exhausted: {:error, :runtime_supervisor_child_missing}
    )
  end

  defp sync_partition_middleware(
         _name,
         _opts,
         _partition_supervisor,
         partition_count,
         _middleware
       )
       when partition_count <= 1 do
    :ok
  end

  defp sync_partition_middleware(name, opts, partition_supervisor, partition_count, middleware)
       when is_pid(partition_supervisor) do
    partition_ids = 0..(partition_count - 1)

    Enum.each(partition_ids, fn partition_id ->
      partition = Partition.via_tuple(name, partition_id, Context.jido_opts(opts))

      case retry_partition_middleware_update(partition, middleware) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Failed to sync middleware to partition #{partition_id} for bus #{name}: #{inspect(reason)}"
          )
      end
    end)

    :ok
  end

  defp sync_partition_middleware(
         _name,
         _opts,
         _partition_supervisor,
         _partition_count,
         _middleware
       ) do
    :ok
  end

  defp safe_partition_middleware_update(partition, middleware) do
    case GenServer.call(partition, {:update_middleware, middleware}) do
      :ok -> :ok
      other -> {:error, {:unexpected_response, other}}
    end
  catch
    :exit, {:noproc, _} -> {:error, :noproc}
    :exit, reason -> {:error, reason}
  end

  defp retry_partition_middleware_update(partition, middleware) do
    Retry.until(
      20,
      fn ->
        case safe_partition_middleware_update(partition, middleware) do
          :ok -> :ok
          {:error, _reason} -> :retry
        end
      end,
      delay_ms: 10,
      factor: 1.0,
      on_exhausted: {:error, :partition_unavailable}
    )
  end

  defp do_init_journal_adapter(_name, journal_adapter, existing_pid)
       when not is_nil(journal_adapter) and not is_nil(existing_pid) do
    {journal_adapter, existing_pid, false}
  end

  defp do_init_journal_adapter(_name, journal_adapter, _existing_pid)
       when not is_nil(journal_adapter) do
    case journal_adapter.init() do
      :ok ->
        {journal_adapter, nil, false}

      {:ok, pid} ->
        {journal_adapter, pid, true}

      {:error, reason} ->
        Logger.warning(
          "Failed to initialize journal adapter #{inspect(journal_adapter)}: #{inspect(reason)}"
        )

        {nil, nil, false}
    end
  end

  defp do_init_journal_adapter(name, _journal_adapter, _existing_pid) do
    Logger.debug(
      "Bus #{name} started without journal adapter - checkpoints will be in-memory only"
    )

    {nil, nil, false}
  end

  # Initializes the bus state with all configuration
  defp init_state(
         name,
         opts,
         child_supervisor,
         partition_supervisor,
         journal_adapter,
         journal_pid,
         journal_owned?,
         middleware_configs
       ) do
    middleware_timeout_ms = Keyword.get(opts, :middleware_timeout_ms, 100)
    partition_count = Keyword.get(opts, :partition_count, 1)
    max_log_size = Keyword.get(opts, :max_log_size, 100_000)
    log_ttl_ms = Keyword.get(opts, :log_ttl_ms)

    gc_timer_ref = schedule_gc_if_needed(log_ttl_ms)

    state = %BusState{
      name: name,
      jido: Keyword.get(opts, :jido),
      router: Keyword.get(opts, :router, Router.new!()),
      bus_supervisor: Keyword.get(opts, :bus_supervisor),
      child_supervisor: child_supervisor,
      child_supervisor_monitor_ref: nil,
      middleware: middleware_configs,
      middleware_timeout_ms: middleware_timeout_ms,
      journal_adapter: journal_adapter,
      journal_pid: journal_pid,
      journal_owned?: journal_owned?,
      async_calls: %{},
      partition_count: partition_count,
      partition_supervisor: partition_supervisor,
      partition_supervisor_monitor_ref: nil,
      max_log_size: max_log_size,
      log_ttl_ms: log_ttl_ms,
      gc_timer_ref: gc_timer_ref,
      gc_task_ref: nil,
      gc_task_pid: nil
    }

    {:ok, state}
  end

  defp schedule_gc_if_needed(nil), do: nil
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
    runtime_supervisor = Names.bus_runtime_supervisor(opts)

    child_spec = %{
      id: {BusSupervisor, name},
      start: {BusSupervisor, :start_link, [opts]},
      type: :supervisor,
      restart: :transient,
      shutdown: 5000
    }

    case DynamicSupervisor.start_child(runtime_supervisor, child_spec) do
      {:ok, _bus_supervisor} ->
        whereis(name, opts)

      {:error, {:already_started, _bus_supervisor}} ->
        whereis(name, opts)

      {:error, {:already_present, _id}} ->
        whereis(name, opts)

      {:error, reason} ->
        {:error, normalize_start_error(reason)}
    end
  end

  @doc false
  @spec start_bus_link(atom(), keyword()) :: GenServer.on_start()
  def start_bus_link(name, opts) do
    GenServer.start_link(__MODULE__, {name, opts}, name: via_tuple(name, opts))
  end

  @doc """
  Returns a namespaced bus registry tuple.

  Uses `{:bus, bus_name}` to avoid key collisions with other registry users.
  """
  @spec via_tuple(atom() | binary(), keyword()) :: {:via, Registry, {module(), tuple()}}
  def via_tuple(name, opts \\ []) when is_atom(name) or is_binary(name) do
    {:via, Registry, {registry(opts), {:bus, name}}}
  end

  @doc """
  Resolves a bus pid from pid/name/registry tuple input.

  Supports both the new namespaced key (`{:bus, name}`) and legacy plain-name
  key for migration compatibility.
  """
  @spec whereis(server(), keyword()) :: {:ok, pid()} | {:error, :not_found}
  def whereis(server, opts \\ [])

  def whereis(pid, _opts) when is_pid(pid), do: {:ok, pid}

  def whereis({name, reg}, _opts) when is_atom(reg) do
    resolve_bus_in_registry(name, reg)
  end

  def whereis(name, opts) when is_atom(name) or is_binary(name) do
    resolve_bus_in_registry(name, registry(opts))
  end

  def whereis(_server, _opts), do: {:error, :not_found}

  @doc """
  Subscribes to signals matching the given path pattern.
  Options:
  - dispatch: How to dispatch signals to the subscriber (default: async to calling process)
  - persistent: Whether the subscription should persist across restarts (default: false)
  """
  @spec subscribe(server(), path(), Keyword.t()) :: {:ok, subscription_id()} | {:error, term()}
  def subscribe(bus, path, opts \\ []) do
    opts = normalize_persistent_subscription_opts(opts)

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

    bus_call(bus, {:subscribe, path, opts})
  end

  defp normalize_persistent_subscription_opts(opts) do
    has_canonical? = Keyword.has_key?(opts, :persistent?)
    legacy_value = Keyword.get(opts, :persistent, nil)

    cond do
      has_canonical? and is_nil(legacy_value) ->
        opts

      has_canonical? ->
        canonical_value = Keyword.get(opts, :persistent?)

        if canonical_value != legacy_value do
          Logger.warning(
            "Both :persistent and :persistent? were provided; using :persistent? and ignoring :persistent"
          )
        end

        Keyword.delete(opts, :persistent)

      true ->
        if is_nil(legacy_value) do
          opts
        else
          Logger.warning("The :persistent option is deprecated; use :persistent? instead")

          opts
          |> Keyword.delete(:persistent)
          |> Keyword.put(:persistent?, legacy_value)
        end
    end
  end

  @doc """
  Unsubscribes from signals using the subscription ID.
  Options:
  - delete_persistence: Whether to delete persistent subscription data (default: false)
  """
  @spec unsubscribe(server(), subscription_id(), Keyword.t()) :: :ok | {:error, term()}
  def unsubscribe(bus, subscription_id, opts \\ []) do
    bus_call(bus, {:unsubscribe, subscription_id, opts})
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
    bus_call(bus, {:publish, signals})
  end

  @doc """
  Replays signals from the bus log that match the given path pattern.
  Optional start_timestamp to replay from a specific point in time.
  """
  @spec replay(server(), path(), non_neg_integer(), Keyword.t()) ::
          {:ok, [Jido.Signal.Bus.RecordedSignal.t()]} | {:error, term()}
  def replay(bus, path \\ "*", start_timestamp \\ 0, opts \\ []) do
    bus_call(bus, {:replay, path, start_timestamp, opts})
  end

  @doc """
  Creates a new snapshot of signals matching the given path pattern.
  """
  @spec snapshot_create(server(), path()) :: {:ok, Snapshot.SnapshotRef.t()} | {:error, term()}
  def snapshot_create(bus, path) do
    bus_call(bus, {:snapshot_create, path})
  end

  @doc """
  Lists all available snapshots.
  """
  @spec snapshot_list(server()) :: [Snapshot.SnapshotRef.t()] | {:error, term()}
  def snapshot_list(bus) do
    bus_call(bus, :snapshot_list)
  end

  @doc """
  Reads a snapshot by its ID.
  """
  @spec snapshot_read(server(), String.t()) :: {:ok, Snapshot.SnapshotData.t()} | {:error, term()}
  def snapshot_read(bus, snapshot_id) do
    bus_call(bus, {:snapshot_read, snapshot_id})
  end

  @doc """
  Deletes a snapshot by its ID.
  """
  @spec snapshot_delete(server(), String.t()) :: :ok | {:error, term()}
  def snapshot_delete(bus, snapshot_id) do
    bus_call(bus, {:snapshot_delete, snapshot_id})
  end

  @doc """
  Acknowledges a signal for a persistent subscription.
  """
  @spec ack(server(), subscription_id(), String.t() | integer()) :: :ok | {:error, term()}
  def ack(bus, subscription_id, signal_id) do
    bus_call(bus, {:ack, subscription_id, signal_id})
  end

  @doc """
  Reconnects a client to a persistent subscription.
  """
  @spec reconnect(server(), subscription_id(), pid()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def reconnect(bus, subscription_id, client_pid) do
    bus_call(bus, {:reconnect, subscription_id, client_pid})
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
    bus_call(bus, {:dlq_entries, subscription_id})
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
    bus_call(bus, {:redrive_dlq, subscription_id, opts})
  end

  @doc """
  Clears all DLQ entries for a subscription.

  ## Returns
  - `:ok` - DLQ cleared
  - `{:error, term()}` - If the operation fails
  """
  @spec clear_dlq(server(), subscription_id()) :: :ok | {:error, term()}
  def clear_dlq(bus, subscription_id) do
    bus_call(bus, {:clear_dlq, subscription_id})
  end

  defp bus_call(bus, message) do
    with {:ok, pid} <- whereis(bus),
         {:ok, target_pid} <- ensure_bus_target_pid(pid) do
      try do
        GenServer.call(target_pid, message)
      catch
        :exit, {:noproc, _} -> {:error, normalize_bus_call_error(:not_found, message)}
        :exit, {:timeout, _} -> {:error, normalize_bus_call_error(:timeout, message)}
      end
    else
      {:error, reason} ->
        {:error, normalize_bus_call_error(reason, message)}
    end
  end

  defp normalize_bus_call_error(:timeout, message) do
    Error.timeout_error("Bus call timed out", %{
      reason: :timeout,
      action: bus_call_action(message)
    })
  end

  defp normalize_bus_call_error(reason, message) do
    Error.execution_error("Bus is unavailable", %{
      reason: normalize_not_found_reason(reason),
      action: bus_call_action(message)
    })
  end

  defp normalize_not_found_reason(reason), do: reason

  defp bus_call_action(message) when is_tuple(message) do
    message
    |> Tuple.to_list()
    |> List.first()
    |> case do
      action when is_atom(action) -> action
      _ -> :unknown
    end
  end

  defp bus_call_action(action) when is_atom(action), do: action

  defp ensure_bus_target_pid(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      nil ->
        {:error, :not_found}

      {:dictionary, dictionary} ->
        case Keyword.get(dictionary, :"$initial_call") do
          {__MODULE__, :init, 1} -> {:ok, pid}
          _ -> {:error, :invalid_bus_target}
        end
    end
  end

  defp start_async_reply(state, from, fun) do
    task =
      Task.Supervisor.async_nolink(
        Names.task_supervisor(Context.jido_opts(state)),
        fun
      )

    async_calls = Map.put(state.async_calls, task.ref, from)
    {:noreply, %{state | async_calls: async_calls}}
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
    if state.partition_count > 1 do
      partition_id = Partition.partition_for(subscription_id, state.partition_count)

      GenServer.cast(
        Partition.via_tuple(state.name, partition_id, Context.jido_opts(state)),
        {:remove_subscription, subscription_id}
      )
    end

    case Subscriber.unsubscribe(state, subscription_id, opts) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:publish, signals}, from, state) do
    task =
      Task.Supervisor.async_nolink(
        Names.task_supervisor(Context.jido_opts(state)),
        fn -> run_publish_pipeline(state, signals) end
      )

    async_calls = Map.put(state.async_calls, task.ref, {:publish, from})
    {:noreply, %{state | async_calls: async_calls}}
  end

  def handle_call({:replay, path, start_timestamp, opts}, from, state) do
    start_async_reply(state, from, fn ->
      case Stream.filter(state, path, start_timestamp, opts) do
        {:ok, signals} -> {:ok, signals}
        {:error, error} -> {:error, error}
      end
    end)
  end

  def handle_call({:snapshot_create, path}, from, state) do
    task =
      Task.Supervisor.async_nolink(
        Names.task_supervisor(Context.jido_opts(state)),
        fn -> Snapshot.create(state, path) end
      )

    async_calls = Map.put(state.async_calls, task.ref, {:snapshot_create, from})
    {:noreply, %{state | async_calls: async_calls}}
  end

  def handle_call(:snapshot_list, _from, state) do
    {:reply, Snapshot.list(state), state}
  end

  def handle_call({:snapshot_read, snapshot_id}, _from, state) do
    case Snapshot.read(state, snapshot_id) do
      {:ok, snapshot_data} ->
        {:reply, {:ok, snapshot_data}, state}

      {:error, error} ->
        {:reply, {:error, normalize_snapshot_boundary_error(error, :snapshot_read, snapshot_id)},
         state}
    end
  end

  def handle_call({:snapshot_delete, snapshot_id}, _from, state) do
    case Snapshot.delete(state, snapshot_id) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, error} ->
        {:reply,
         {:error, normalize_snapshot_boundary_error(error, :snapshot_delete, snapshot_id)}, state}
    end
  end

  def handle_call({:ack, subscription_id, signal_id}, from, state) do
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
        start_async_reply(state, from, fn ->
          ack_persistent_subscription(subscription, signal_id, state)
        end)
    end
  end

  def handle_call({:reconnect, subscriber_id, client_pid}, _from, state) do
    case BusState.get_subscription(state, subscriber_id) do
      nil ->
        {:reply, {:error, subscription_not_found_error(subscriber_id, :reconnect)}, state}

      subscription ->
        do_reconnect(state, subscriber_id, client_pid, subscription)
    end
  end

  def handle_call({:dlq_entries, _subscription_id}, _from, %{journal_adapter: nil} = state) do
    {:reply, {:error, no_journal_adapter_error(:dlq_entries)}, state}
  end

  def handle_call({:dlq_entries, subscription_id}, from, state) do
    task =
      Task.Supervisor.async_nolink(
        Names.task_supervisor(Context.jido_opts(state)),
        fn -> adapter_get_dlq_entries(state, subscription_id, []) end
      )

    async_calls = Map.put(state.async_calls, task.ref, {:dlq_entries, from})
    {:noreply, %{state | async_calls: async_calls}}
  end

  def handle_call({:redrive_dlq, _subscription_id, _opts}, _from, %{journal_adapter: nil} = state) do
    {:reply, {:error, no_journal_adapter_error(:redrive_dlq)}, state}
  end

  def handle_call({:redrive_dlq, subscription_id, opts}, from, state) do
    task =
      Task.Supervisor.async_nolink(
        Names.task_supervisor(Context.jido_opts(state)),
        fn -> do_redrive_dlq(state, subscription_id, opts) end
      )

    async_calls = Map.put(state.async_calls, task.ref, from)
    {:noreply, %{state | async_calls: async_calls}}
  end

  def handle_call({:clear_dlq, _subscription_id}, _from, %{journal_adapter: nil} = state) do
    {:reply, {:error, no_journal_adapter_error(:clear_dlq)}, state}
  end

  def handle_call({:clear_dlq, subscription_id}, from, state) do
    task =
      Task.Supervisor.async_nolink(
        Names.task_supervisor(Context.jido_opts(state)),
        fn -> adapter_clear_dlq(state, subscription_id, []) end
      )

    async_calls = Map.put(state.async_calls, task.ref, {:clear_dlq, from})
    {:noreply, %{state | async_calls: async_calls}}
  end

  # Private helpers for handle_call callbacks

  defp run_publish_pipeline(state, signals) do
    context = %{
      bus_name: state.name,
      jido: state.jido,
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
      {:ok, recorded_signals, final_state} -> {:ok, recorded_signals, final_state}
      {:error, error} -> {:error, error}
    end
  end

  defp sync_subscription_to_partition(_new_state, _subscription_id, %{partition_count: count})
       when count <= 1,
       do: :ok

  defp sync_subscription_to_partition(new_state, subscription_id, state) do
    subscription = BusState.get_subscription(new_state, subscription_id)
    partition_id = Partition.partition_for(subscription_id, state.partition_count)

    GenServer.cast(
      Partition.via_tuple(state.name, partition_id, Context.jido_opts(state)),
      {:add_subscription, subscription_id, subscription}
    )
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
        log_id: uuid,
        type: signal.type,
        created_at: DateTime.utc_now(),
        signal: signal
      }
    end)
  end

  defp do_reconnect(state, subscriber_id, client_pid, %{persistent?: true} = subscription) do
    updated_subscription = update_subscription_dispatch(subscription, client_pid)
    {final_state, latest_timestamp} = apply_reconnect(state, subscriber_id, updated_subscription)
    persistence_target = persistence_target(subscription, state)
    checkpoint = fetch_persistent_checkpoint(persistence_target)
    missed_signals = replayable_signals(final_state, updated_subscription.path, checkpoint)

    if persistence_target do
      GenServer.cast(persistence_target, {:reconnect, client_pid, missed_signals})
    end

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
    |> Map.keys()
    |> Enum.reduce(0, fn log_id, acc ->
      case safe_log_timestamp(log_id) do
        {:ok, timestamp} -> max(acc, timestamp)
        :error -> acc
      end
    end)
  end

  defp fetch_persistent_checkpoint(nil), do: 0

  defp fetch_persistent_checkpoint(persistence_target) do
    GenServer.call(persistence_target, :checkpoint)
  catch
    :exit, _ -> 0
  end

  defp replayable_signals(state, path, checkpoint) do
    state.log
    |> Enum.sort_by(fn {log_id, _signal} -> log_id end)
    |> Enum.filter(fn {log_id, signal} ->
      case safe_log_timestamp(log_id) do
        {:ok, timestamp} ->
          timestamp > checkpoint and Router.matches?(signal.type, path)

        :error ->
          false
      end
    end)
    |> Enum.map(fn {log_id, signal} -> {log_id, signal} end)
  end

  defp safe_log_timestamp(log_id) do
    {:ok, ID.extract_timestamp(log_id)}
  rescue
    _ -> :error
  end

  defp do_redrive_dlq(state, subscription_id, opts) do
    limit = Keyword.get(opts, :limit, :infinity)
    clear_on_success = Keyword.get(opts, :clear_on_success, true)

    with {:ok, entries} <- adapter_get_dlq_entries(state, subscription_id, limit: limit),
         {:ok, subscription} <- fetch_subscription(state, subscription_id) do
      entries_to_process = limit_entries(entries, limit)
      result = process_dlq_entries(state, entries_to_process, subscription, clear_on_success)
      emit_redrive_telemetry(state.name, subscription_id, result)
      {:ok, result}
    end
  end

  defp fetch_subscription(state, subscription_id) do
    case BusState.get_subscription(state, subscription_id) do
      nil -> {:error, subscription_not_found_error(subscription_id, :redrive_dlq)}
      subscription -> {:ok, subscription}
    end
  end

  defp limit_entries(entries, :infinity), do: entries
  defp limit_entries(entries, limit), do: Enum.take(entries, limit)

  defp adapter_get_dlq_entries(state, subscription_id, opts) do
    if function_exported?(state.journal_adapter, :get_dlq_entries, 3) do
      state.journal_adapter.get_dlq_entries(subscription_id, state.journal_pid, opts)
    else
      with {:ok, entries} <-
             state.journal_adapter.get_dlq_entries(subscription_id, state.journal_pid) do
        {:ok, limit_entries(entries, Keyword.get(opts, :limit, :infinity))}
      end
    end
  end

  defp adapter_clear_dlq(state, subscription_id, opts) do
    if function_exported?(state.journal_adapter, :clear_dlq, 3) do
      state.journal_adapter.clear_dlq(subscription_id, state.journal_pid, opts)
    else
      state.journal_adapter.clear_dlq(subscription_id, state.journal_pid)
    end
  end

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
    with :ok <- SignalValidation.validate_signals(signals),
         {:ok, new_state, uuid_signal_pairs} <- BusState.append_signals(state, signals) do
      if state.partition_count <= 1 do
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
        broadcast_to_partitions(state, signals, uuid_signal_pairs, context)
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
    state.subscriptions
    |> Enum.reduce([], fn {subscription_id, subscription}, acc ->
      enqueue_persistent_subscription(
        acc,
        state,
        subscription_id,
        subscription,
        signals,
        signal_log_id_map
      )
    end)
  end

  defp enqueue_persistent_subscription(
         acc,
         _state,
         _subscription_id,
         %{persistent?: false},
         _signals,
         _signal_log_id_map
       ),
       do: acc

  defp enqueue_persistent_subscription(
         acc,
         state,
         subscription_id,
         subscription,
         signals,
         signal_log_id_map
       ) do
    case build_persistent_signal_batch(signals, subscription, signal_log_id_map) do
      [] ->
        acc

      signal_batch ->
        persistence_target = persistence_target(subscription, state)

        [
          {subscription_id,
           enqueue_persistent_batch(subscription, persistence_target, signal_batch)}
          | acc
        ]
    end
  end

  defp build_persistent_signal_batch(signals, subscription, signal_log_id_map) do
    signals
    |> Enum.reduce([], fn signal, acc ->
      maybe_add_persistent_signal(acc, signal, subscription.path, signal_log_id_map)
    end)
    |> Enum.reverse()
  end

  defp maybe_add_persistent_signal(acc, signal, path, signal_log_id_map) do
    with true <- Router.matches?(signal.type, path),
         {:ok, signal_log_id} <- Map.fetch(signal_log_id_map, signal.id) do
      [{signal_log_id, signal} | acc]
    else
      _ -> acc
    end
  end

  defp find_saturated_subscriptions(results) do
    Enum.filter(results, fn
      {_id, {:error, :queue_full}} -> true
      _ -> false
    end)
  end

  defp broadcast_to_partitions(state, signals, uuid_signal_pairs, context) do
    Enum.each(0..(state.partition_count - 1), fn partition_id ->
      GenServer.cast(
        Partition.via_tuple(state.name, partition_id, Context.jido_opts(state)),
        {:dispatch, signals, uuid_signal_pairs, context}
      )
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
    case DispatchPipeline.dispatch_with_middleware(
           acc_middleware,
           signal,
           subscription_id,
           subscription,
           dispatch_ctx.context,
           dispatch_ctx.timeout_ms,
           fn processed_signal, current_subscription ->
             dispatch_to_subscription(
               processed_signal,
               current_subscription,
               dispatch_ctx.signal_log_id_map,
               dispatch_ctx.state
             )
           end,
           %{bus_name: dispatch_ctx.state.name}
         ) do
      {:dispatch, new_middleware, result} ->
        {new_middleware, [{subscription_id, result} | acc_results]}

      {:skip, new_middleware} ->
        {new_middleware, acc_results}

      {:middleware_error, new_middleware, _reason} ->
        {new_middleware, acc_results}
    end
  end

  # Dispatch signal to a subscription
  # For persistent subscriptions, use synchronous call to get backpressure feedback
  # For regular subscriptions, use normal async dispatch
  defp dispatch_to_subscription(signal, subscription, signal_log_id_map, state) do
    persistence_target = persistence_target(subscription, state)

    if subscription.persistent? && persistence_target do
      signal_log_id = Map.get(signal_log_id_map, signal.id)

      if is_binary(signal_log_id) do
        enqueue_persistent_batch(subscription, persistence_target, [{signal_log_id, signal}])
      else
        {:error, :missing_signal_log_id}
      end
    else
      # For regular subscriptions, use async dispatch
      DispatchPipeline.dispatch_async(signal, subscription, Context.jido_opts(state))
    end
  end

  defp enqueue_persistent_batch(_subscription, nil, _signal_batch),
    do: {:error, :subscription_not_available}

  defp enqueue_persistent_batch(_subscription, persistence_target, signal_batch) do
    publish_ref = make_ref()

    try do
      GenServer.cast(
        persistence_target,
        {:signal_batch, signal_batch, self(), publish_ref}
      )

      receive do
        {:persistent_enqueue_result, ^publish_ref, result} ->
          result
      after
        @persistent_enqueue_timeout_ms ->
          {:error, :subscription_not_available}
      end
    catch
      :exit, {:noproc, _} ->
        {:error, :subscription_not_available}

      :exit, _reason ->
        {:error, :subscription_not_available}
    end
  end

  @impl GenServer
  def handle_info(
        {ref, {:gc_log_pruned, new_log, removed_count}},
        %{gc_task_ref: ref} = state
      )
      when is_reference(ref) and is_map(new_log) and is_integer(removed_count) do
    Process.demonitor(ref, [:flush])
    emit_gc_telemetry_if_pruned(state, removed_count, map_size(new_log))

    {:noreply, %{state | log: new_log, gc_task_ref: nil, gc_task_pid: nil}}
  end

  @impl GenServer
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.async_calls, ref) do
      {nil, _async_calls} ->
        {:noreply, state}

      {entry, async_calls} ->
        Process.demonitor(ref, [:flush])
        handle_async_result(entry, async_calls, result, state)
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    cond do
      ref == state.gc_task_ref ->
        handle_gc_task_down(pid, reason, state)

      Map.has_key?(state.async_calls, ref) ->
        {entry, async_calls} = Map.pop(state.async_calls, ref)
        from = normalize_async_from(entry)
        GenServer.reply(from, {:error, {:async_task_exit, reason}})
        {:noreply, %{state | async_calls: async_calls}}

      ref == state.child_supervisor_monitor_ref ->
        Logger.error("Bus child supervisor exited (#{inspect(pid)}): #{inspect(reason)}")
        {:stop, {:child_supervisor_down, pid, reason}, state}

      ref == state.partition_supervisor_monitor_ref ->
        Logger.error("Partition supervisor exited (#{inspect(pid)}): #{inspect(reason)}")
        {:stop, {:partition_supervisor_down, pid, reason}, state}

      true ->
        handle_subscription_down(pid, reason, state)
    end
  end

  @impl GenServer
  def handle_info({:persistent_backpressure, subscription_id, _publish_ref, dropped_count}, state) do
    Telemetry.execute(
      [:jido, :signal, :bus, :persistent_backpressure],
      %{dropped_count: dropped_count},
      %{bus_name: state.name, subscription_id: subscription_id}
    )

    {:noreply, state}
  end

  def handle_info(:gc_log, %{log_ttl_ms: nil} = state), do: {:noreply, state}

  def handle_info(:gc_log, state) do
    gc_timer_ref = Process.send_after(self(), :gc_log, state.log_ttl_ms)
    state = %{state | gc_timer_ref: gc_timer_ref}
    {:noreply, maybe_start_gc_prune(state)}
  end

  def handle_info(msg, state) do
    Logger.debug("Unexpected message in Bus: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_subscription_down(pid, reason, state) do
    case Enum.find(state.subscriptions, fn {_id, sub} -> sub.persistence_pid == pid end) do
      nil ->
        {:noreply, state}

      {subscription_id, subscription} ->
        Logger.info("Subscription #{subscription_id} process terminated: #{inspect(reason)}")
        new_subscription = %{subscription | persistence_pid: nil, disconnected?: true}
        new_subscriptions = Map.put(state.subscriptions, subscription_id, new_subscription)
        {:noreply, %{state | subscriptions: new_subscriptions}}
    end
  end

  defp maybe_start_gc_prune(%{gc_task_ref: ref} = state) when is_reference(ref), do: state

  defp maybe_start_gc_prune(state) do
    task_supervisor = Names.task_supervisor(Context.jido_opts(state))

    try do
      task =
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          prune_expired_log_entries(state.log, state.log_ttl_ms)
        end)

      %{state | gc_task_ref: task.ref, gc_task_pid: task.pid}
    catch
      :exit, reason ->
        Logger.warning("Failed to start log GC task for #{state.name}: #{inspect(reason)}")

        %{state | gc_task_ref: nil, gc_task_pid: nil}
    end
  end

  defp prune_expired_log_entries(log, log_ttl_ms) do
    cutoff_time = DateTime.add(DateTime.utc_now(), -log_ttl_ms, :millisecond)
    original_size = map_size(log)

    new_log =
      log
      |> Enum.filter(&signal_not_expired?(&1, cutoff_time))
      |> Map.new()

    {:gc_log_pruned, new_log, original_size - map_size(new_log)}
  end

  defp signal_not_expired?({_uuid, signal}, cutoff_time) do
    case DateTime.from_iso8601(signal.time) do
      {:ok, signal_time, _} -> DateTime.compare(signal_time, cutoff_time) != :lt
      _ -> true
    end
  end

  defp emit_gc_telemetry_if_pruned(state, removed_count, new_size) do
    if removed_count > 0 do
      Telemetry.execute(
        [:jido, :signal, :bus, :log_gc],
        %{removed_count: removed_count},
        %{bus_name: state.name, new_size: new_size, ttl_ms: state.log_ttl_ms}
      )
    end
  end

  defp handle_gc_task_down(_pid, :normal, state) do
    {:noreply, %{state | gc_task_ref: nil, gc_task_pid: nil}}
  end

  defp handle_gc_task_down(pid, reason, state) do
    Logger.warning("Log GC task exited (#{inspect(pid)}): #{inspect(reason)}")
    {:noreply, %{state | gc_task_ref: nil, gc_task_pid: nil}}
  end

  @impl GenServer
  def terminate(reason, state) do
    if state.gc_timer_ref, do: Process.cancel_timer(state.gc_timer_ref)
    stop_gc_task(state)
    maybe_stop_bus_supervisor(reason, state)
    stop_owned_journal(state)
    _ = Snapshot.cleanup(state)
    :ok
  end

  defp stop_gc_task(%{gc_task_pid: pid, gc_task_ref: ref}) when is_pid(pid) do
    Process.demonitor(ref, [:flush])

    if Process.alive?(pid) do
      Process.exit(pid, :kill)
    end
  catch
    :error, _ -> :ok
  end

  defp stop_gc_task(_state), do: :ok

  defp ack_persistent_subscription(subscription, signal_id, state) do
    case persistence_target(subscription, state) do
      nil ->
        {:error,
         Error.execution_error("Persistent subscription is unavailable", %{
           reason: :subscription_not_available
         })}

      target ->
        try do
          GenServer.call(target, {:ack, signal_id})
          :ok
        catch
          :exit, {:noproc, _} ->
            {:error,
             Error.execution_error("Persistent subscription is unavailable", %{
               reason: :subscription_not_available
             })}

          :exit, {:timeout, _} ->
            {:error,
             Error.timeout_error("Persistent subscription acknowledgement timed out", %{
               reason: :timeout
             })}

          :exit, _ ->
            {:error,
             Error.execution_error("Persistent subscription is unavailable", %{
               reason: :subscription_not_available
             })}
        end
    end
  end

  defp registry(opts) do
    case Keyword.get(opts, :jido) do
      nil -> Keyword.get(opts, :registry, Jido.Signal.Registry)
      _ -> Names.registry(opts)
    end
  end

  defp resolve_bus_in_registry(name, reg) when is_atom(reg) do
    case Registry.lookup(reg, {:bus, name}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        # Backwards-compatible fallback for buses registered before namespaced keys.
        legacy_name = if is_atom(name), do: Atom.to_string(name), else: name

        case Registry.lookup(reg, legacy_name) do
          [{pid, _}] -> {:ok, pid}
          [] -> {:error, :not_found}
        end
    end
  end

  defp normalize_async_from({:snapshot_create, from}), do: from
  defp normalize_async_from(from), do: from

  defp handle_async_result({:snapshot_create, from}, async_calls, result, state) do
    case result do
      {:ok, snapshot_ref, new_state} ->
        GenServer.reply(from, {:ok, snapshot_ref})
        {:noreply, %{new_state | async_calls: async_calls}}

      {:error, error} ->
        GenServer.reply(
          from,
          {:error, normalize_snapshot_boundary_error(error, :snapshot_create)}
        )

        {:noreply, %{state | async_calls: async_calls}}
    end
  end

  defp handle_async_result({:publish, from}, async_calls, result, state) do
    case result do
      {:ok, recorded_signals, new_state} ->
        GenServer.reply(from, {:ok, recorded_signals})
        {:noreply, %{new_state | async_calls: async_calls}}

      {:error, error} ->
        GenServer.reply(from, {:error, error})
        {:noreply, %{state | async_calls: async_calls}}
    end
  end

  defp handle_async_result({:dlq_entries, from}, async_calls, result, state) do
    GenServer.reply(from, result)
    {:noreply, %{state | async_calls: async_calls}}
  end

  defp handle_async_result({:clear_dlq, from}, async_calls, result, state) do
    GenServer.reply(from, result)
    {:noreply, %{state | async_calls: async_calls}}
  end

  defp handle_async_result(from, async_calls, result, state) do
    GenServer.reply(from, result)
    {:noreply, %{state | async_calls: async_calls}}
  end

  defp normalize_start_error(
         {:shutdown,
          {:failed_to_start_child, {__MODULE__, _bus_name}, {:bus_init_failed, reason}}}
       ) do
    {:bus_init_failed, reason}
  end

  defp normalize_start_error(reason), do: reason

  defp stop_owned_journal(%{journal_owned?: true, journal_pid: pid}) when is_pid(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  defp stop_owned_journal(_state), do: :ok

  defp maybe_stop_bus_supervisor(:normal, %{bus_supervisor: bus_supervisor})
       when is_pid(bus_supervisor) do
    spawn(fn ->
      try do
        Supervisor.stop(bus_supervisor, :normal)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  defp maybe_stop_bus_supervisor(_reason, _state), do: :ok

  defp normalize_snapshot_boundary_error(error, action, snapshot_id \\ nil)

  defp normalize_snapshot_boundary_error(:not_found, action, snapshot_id) do
    details =
      %{
        field: :snapshot_id,
        reason: :snapshot_not_found,
        action: action
      }
      |> maybe_put_snapshot_id(snapshot_id)

    Error.validation_error("Snapshot does not exist", details)
  end

  defp normalize_snapshot_boundary_error(%_{} = error, _action, _snapshot_id), do: error

  defp normalize_snapshot_boundary_error(reason, action, snapshot_id) do
    details =
      %{
        reason: reason,
        action: action
      }
      |> maybe_put_snapshot_id(snapshot_id)

    Error.execution_error("Snapshot operation failed", details)
  end

  defp maybe_put_snapshot_id(details, nil), do: details

  defp maybe_put_snapshot_id(details, snapshot_id),
    do: Map.put(details, :snapshot_id, snapshot_id)

  defp no_journal_adapter_error(action) do
    Error.execution_error("Journal adapter is not configured", %{
      action: action,
      reason: :no_journal_adapter
    })
  end

  defp subscription_not_found_error(subscription_id, action) do
    Error.validation_error("Subscription does not exist", %{
      field: :subscription_id,
      value: subscription_id,
      action: action,
      reason: :subscription_not_found
    })
  end

  defp persistence_target(subscription) when is_map(subscription) do
    subscription
    |> Map.get(:persistence_ref)
    |> PersistentRef.target()
    |> case do
      nil -> PersistentRef.target(Map.get(subscription, :persistence_pid))
      target -> target
    end
  end

  defp persistence_target(subscription, state) when is_map(subscription) do
    ref = PersistentRef.from_subscription(subscription, state.name, Context.jido_opts(state))
    target = PersistentRef.target(ref)
    target || persistence_target(subscription)
  end
end
