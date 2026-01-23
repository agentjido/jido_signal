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
  use TypedStruct

  alias Jido.Signal.Bus.MiddlewarePipeline
  alias Jido.Signal.Bus.Partition
  alias Jido.Signal.Bus.PartitionSupervisor
  alias Jido.Signal.Bus.Snapshot
  alias Jido.Signal.Bus.State, as: BusState
  alias Jido.Signal.Bus.Stream
  alias Jido.Signal.Error
  alias Jido.Signal.Router

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
    # Trap exits so we can handle subscriber termination
    Process.flag(:trap_exit, true)

    {:ok, child_supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    # Resolve journal adapter from opts or application config
    journal_adapter =
      Keyword.get(opts, :journal_adapter) ||
        Application.get_env(:jido_signal, :journal_adapter)

    # Note: journal_adapter_opts is resolved for future use when adapters
    # support custom initialization options
    _journal_adapter_opts =
      Keyword.get(opts, :journal_adapter_opts) ||
        Application.get_env(:jido_signal, :journal_adapter_opts, [])

    # Initialize journal adapter if configured
    # Allow passing an existing journal_pid (useful for testing or shared adapters)
    existing_journal_pid = Keyword.get(opts, :journal_pid)

    {journal_adapter, journal_pid} =
      cond do
        # If journal_pid is provided, use it directly
        journal_adapter && existing_journal_pid ->
          {journal_adapter, existing_journal_pid}

        # If only adapter is provided, initialize it
        journal_adapter ->
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

        # No adapter configured
        true ->
          Logger.debug(
            "Bus #{name} started without journal adapter - checkpoints will be in-memory only"
          )

          {nil, nil}
      end

    # Initialize middleware
    middleware_specs = Keyword.get(opts, :middleware, [])

    case MiddlewarePipeline.init_middleware(middleware_specs) do
      {:ok, middleware_configs} ->
        middleware_timeout_ms = Keyword.get(opts, :middleware_timeout_ms, 100)
        partition_count = Keyword.get(opts, :partition_count, 1)
        max_log_size = Keyword.get(opts, :max_log_size, 100_000)
        log_ttl_ms = Keyword.get(opts, :log_ttl_ms)

        partition_pids =
          if partition_count > 1 do
            partition_opts = [
              partition_count: partition_count,
              bus_name: name,
              bus_pid: self(),
              middleware: middleware_configs,
              middleware_timeout_ms: middleware_timeout_ms,
              journal_adapter: journal_adapter,
              journal_pid: journal_pid,
              rate_limit_per_sec: Keyword.get(opts, :partition_rate_limit_per_sec, 10_000),
              burst_size: Keyword.get(opts, :partition_burst_size, 1_000)
            ]

            {:ok, _sup_pid} = PartitionSupervisor.start_link(partition_opts)

            for i <- 0..(partition_count - 1) do
              GenServer.whereis(Partition.via_tuple(name, i))
            end
            |> Enum.reject(&is_nil/1)
          else
            []
          end

        # Schedule periodic GC if log_ttl_ms is set
        if log_ttl_ms do
          Process.send_after(self(), :gc_log, log_ttl_ms)
        end

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

      {:error, reason} ->
        {:stop, {:middleware_init_failed, reason}}
    end
  end

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
    subscription_id = Keyword.get(opts, :subscription_id, Jido.Signal.ID.generate!())
    opts = Keyword.put(opts, :subscription_id, subscription_id)

    case Jido.Signal.Bus.Subscriber.subscribe(state, subscription_id, path, opts) do
      {:ok, new_state} ->
        if not Enum.empty?(state.partition_pids) do
          subscription = BusState.get_subscription(new_state, subscription_id)
          partition_id = Partition.partition_for(subscription_id, state.partition_count)
          partition_pid = Enum.at(state.partition_pids, partition_id)

          if partition_pid do
            GenServer.call(partition_pid, {:add_subscription, subscription_id, subscription})
          end
        end

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

    case Jido.Signal.Bus.Subscriber.unsubscribe(state, subscription_id, opts) do
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

    # Run before_publish middleware - captures updated middleware configs
    case MiddlewarePipeline.before_publish(
           state.middleware,
           signals,
           context,
           state.middleware_timeout_ms
         ) do
      {:ok, processed_signals, updated_middleware} ->
        # Update state with middleware changes from before_publish
        state_with_middleware = %{state | middleware: updated_middleware}

        case publish_with_middleware(
               state_with_middleware,
               processed_signals,
               context,
               state.middleware_timeout_ms
             ) do
          {:ok, new_state, uuid_signal_pairs} ->
            # Run after_publish middleware and capture state changes
            final_middleware =
              MiddlewarePipeline.after_publish(
                new_state.middleware,
                processed_signals,
                context,
                state.middleware_timeout_ms
              )

            final_state = %{new_state | middleware: final_middleware}

            # Create RecordedSignal structs from the uuid_signal_pairs
            recorded_signals =
              Enum.map(uuid_signal_pairs, fn {uuid, signal} ->
                %Jido.Signal.Bus.RecordedSignal{
                  id: uuid,
                  type: signal.type,
                  created_at: DateTime.utc_now(),
                  signal: signal
                }
              end)

            {:reply, {:ok, recorded_signals}, final_state}

          {:error, error} ->
            {:reply, {:error, error}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
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
        if subscription.persistent? do
          # Update the client PID in the subscription
          updated_subscription = %{
            subscription
            | dispatch: {:pid, [delivery_mode: :async, target: client_pid]}
          }

          case BusState.add_subscription(state, subscriber_id, updated_subscription) do
            {:error, :subscription_exists} ->
              # If subscription already exists, notify the persistence process and get latest timestamp
              GenServer.cast(subscription.persistence_pid, {:reconnect, client_pid})

              latest_timestamp =
                state.log
                |> Map.values()
                |> Enum.map(& &1.time)
                |> Enum.max(fn -> 0 end)

              {:reply, {:ok, latest_timestamp}, state}

            {:ok, updated_state} ->
              # Notify the persistence process and get latest timestamp
              GenServer.cast(subscription.persistence_pid, {:reconnect, client_pid})

              latest_timestamp =
                updated_state.log
                |> Map.values()
                |> Enum.map(& &1.time)
                |> Enum.max(fn -> 0 end)

              {:reply, {:ok, latest_timestamp}, updated_state}
          end
        else
          # For non-persistent subscriptions, just update the client PID
          updated_subscription = %{
            subscription
            | dispatch: {:pid, [delivery_mode: :async, target: client_pid]}
          }

          case BusState.add_subscription(state, subscriber_id, updated_subscription) do
            {:error, :subscription_exists} ->
              # If subscription already exists, just get the latest timestamp
              latest_timestamp =
                state.log
                |> Map.values()
                |> Enum.map(& &1.time)
                |> Enum.max(fn -> 0 end)

              {:reply, {:ok, latest_timestamp}, state}

            {:ok, updated_state} ->
              # Get the latest signal timestamp from the log
              latest_timestamp =
                updated_state.log
                |> Map.values()
                |> Enum.map(& &1.time)
                |> Enum.max(fn -> 0 end)

              {:reply, {:ok, latest_timestamp}, updated_state}
          end
        end
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

  def handle_call({:redrive_dlq, subscription_id, opts}, _from, state) do
    if state.journal_adapter do
      limit = Keyword.get(opts, :limit, :infinity)
      clear_on_success = Keyword.get(opts, :clear_on_success, true)

      case state.journal_adapter.get_dlq_entries(subscription_id, state.journal_pid) do
        {:ok, entries} ->
          entries_to_process =
            if limit == :infinity,
              do: entries,
              else: Enum.take(entries, limit)

          subscription = BusState.get_subscription(state, subscription_id)

          if subscription do
            results =
              Enum.map(entries_to_process, fn entry ->
                case Jido.Signal.Dispatch.dispatch(entry.signal, subscription.dispatch) do
                  :ok ->
                    if clear_on_success do
                      state.journal_adapter.delete_dlq_entry(entry.id, state.journal_pid)
                    end

                    :ok

                  {:error, _reason} = error ->
                    error
                end
              end)

            succeeded = Enum.count(results, &(&1 == :ok))
            failed = length(results) - succeeded

            :telemetry.execute(
              [:jido, :signal, :bus, :dlq, :redrive],
              %{succeeded: succeeded, failed: failed},
              %{bus_name: state.name, subscription_id: subscription_id}
            )

            {:reply, {:ok, %{succeeded: succeeded, failed: failed}}, state}
          else
            {:reply, {:error, :subscription_not_found}, state}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :no_journal_adapter}, state}
    end
  end

  def handle_call({:clear_dlq, subscription_id}, _from, state) do
    if state.journal_adapter do
      result = state.journal_adapter.clear_dlq(subscription_id, state.journal_pid)
      {:reply, result, state}
    else
      {:reply, {:error, :no_journal_adapter}, state}
    end
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
    # For partitioned mode, we dispatch to partitions asynchronously
    # But persistent subscriptions still need backpressure handling from main bus
    # so we dispatch those synchronously here first
    persistent_results =
      Enum.flat_map(signals, fn signal ->
        state.subscriptions
        |> Enum.filter(fn {_id, sub} ->
          sub.persistent? && Router.matches?(signal.type, sub.path)
        end)
        |> Enum.map(fn {subscription_id, subscription} ->
          signal_log_id_map =
            Map.new(uuid_signal_pairs, fn {uuid, sig} -> {sig.id, uuid} end)

          result = dispatch_to_subscription(signal, subscription, signal_log_id_map)
          {subscription_id, result}
        end)
      end)

    saturated =
      Enum.filter(persistent_results, fn
        {_id, {:error, :queue_full}} -> true
        _ -> false
      end)

    case saturated do
      [] ->
        # Cast to all partitions for non-persistent subscriptions
        Enum.each(state.partition_pids, fn partition_pid ->
          GenServer.cast(partition_pid, {:dispatch, signals, uuid_signal_pairs, context})
        end)

        {:ok, state, uuid_signal_pairs}

      [{subscription_id, _} | _] ->
        :telemetry.execute(
          [:jido, :signal, :bus, :backpressure],
          %{saturated_count: length(saturated)},
          %{bus_name: state.name}
        )

        {:error,
         Error.execution_error(
           "Subscription saturated",
           %{subscription_id: subscription_id, reason: :queue_full}
         )}
    end
  end

  # Original non-partitioned dispatch with full middleware support
  defp publish_without_partitions(new_state, signals, uuid_signal_pairs, context, timeout_ms) do
    signal_log_id_map =
      Map.new(uuid_signal_pairs, fn {uuid, signal} -> {signal.id, uuid} end)

    {final_middleware, dispatch_results} =
      Enum.reduce(signals, {new_state.middleware, []}, fn signal,
                                                          {current_middleware, results_acc} ->
        Enum.reduce(
          new_state.subscriptions,
          {current_middleware, results_acc},
          fn {subscription_id, subscription}, {acc_middleware, acc_results} ->
            if Router.matches?(signal.type, subscription.path) do
              :telemetry.execute(
                [:jido, :signal, :bus, :before_dispatch],
                %{timestamp: System.monotonic_time(:microsecond)},
                %{
                  bus_name: new_state.name,
                  signal_id: signal.id,
                  signal_type: signal.type,
                  subscription_id: subscription_id,
                  subscription_path: subscription.path,
                  signal: signal,
                  subscription: subscription
                }
              )

              case MiddlewarePipeline.before_dispatch(
                     acc_middleware,
                     signal,
                     subscription,
                     context,
                     timeout_ms
                   ) do
                {:ok, processed_signal, updated_middleware} ->
                  result =
                    dispatch_to_subscription(
                      processed_signal,
                      subscription,
                      signal_log_id_map
                    )

                  :telemetry.execute(
                    [:jido, :signal, :bus, :after_dispatch],
                    %{timestamp: System.monotonic_time(:microsecond)},
                    %{
                      bus_name: new_state.name,
                      signal_id: processed_signal.id,
                      signal_type: processed_signal.type,
                      subscription_id: subscription_id,
                      subscription_path: subscription.path,
                      dispatch_result: result,
                      signal: processed_signal,
                      subscription: subscription
                    }
                  )

                  new_middleware =
                    MiddlewarePipeline.after_dispatch(
                      updated_middleware,
                      processed_signal,
                      subscription,
                      result,
                      context,
                      timeout_ms
                    )

                  {new_middleware, [{subscription_id, result} | acc_results]}

                :skip ->
                  :telemetry.execute(
                    [:jido, :signal, :bus, :dispatch_skipped],
                    %{timestamp: System.monotonic_time(:microsecond)},
                    %{
                      bus_name: new_state.name,
                      signal_id: signal.id,
                      signal_type: signal.type,
                      subscription_id: subscription_id,
                      subscription_path: subscription.path,
                      reason: :middleware_skip,
                      signal: signal,
                      subscription: subscription
                    }
                  )

                  {acc_middleware, acc_results}

                {:error, reason} ->
                  :telemetry.execute(
                    [:jido, :signal, :bus, :dispatch_error],
                    %{timestamp: System.monotonic_time(:microsecond)},
                    %{
                      bus_name: new_state.name,
                      signal_id: signal.id,
                      signal_type: signal.type,
                      subscription_id: subscription_id,
                      subscription_path: subscription.path,
                      error: reason,
                      signal: signal,
                      subscription: subscription
                    }
                  )

                  Logger.warning(
                    "Middleware halted dispatch for signal #{signal.id}: #{inspect(reason)}"
                  )

                  {acc_middleware, acc_results}
              end
            else
              {acc_middleware, acc_results}
            end
          end
        )
      end)

    saturated =
      Enum.filter(dispatch_results, fn
        {_id, {:error, :queue_full}} -> true
        _ -> false
      end)

    case saturated do
      [] ->
        {:ok, %{new_state | middleware: final_middleware}, uuid_signal_pairs}

      [{subscription_id, _} | _] ->
        :telemetry.execute(
          [:jido, :signal, :bus, :backpressure],
          %{saturated_count: length(saturated)},
          %{bus_name: new_state.name}
        )

        {:error,
         Error.execution_error(
           "Subscription saturated",
           %{subscription_id: subscription_id, reason: :queue_full}
         )}
    end
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
      Jido.Signal.Dispatch.dispatch(signal, subscription.dispatch)
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

  def handle_info(:gc_log, state) do
    if state.log_ttl_ms do
      # Schedule next GC
      Process.send_after(self(), :gc_log, state.log_ttl_ms)

      # Prune signals older than TTL
      cutoff_time = DateTime.add(DateTime.utc_now(), -state.log_ttl_ms, :millisecond)
      original_size = map_size(state.log)

      new_log =
        state.log
        |> Enum.filter(fn {_uuid, signal} ->
          case DateTime.from_iso8601(signal.time) do
            {:ok, signal_time, _} -> DateTime.compare(signal_time, cutoff_time) != :lt
            _ -> true
          end
        end)
        |> Map.new()

      removed_count = original_size - map_size(new_log)

      if removed_count > 0 do
        :telemetry.execute(
          [:jido, :signal, :bus, :log_gc],
          %{removed_count: removed_count},
          %{bus_name: state.name, new_size: map_size(new_log), ttl_ms: state.log_ttl_ms}
        )
      end

      {:noreply, %{state | log: new_log}}
    else
      {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("Unexpected message in Bus: #{inspect(msg)}")
    {:noreply, state}
  end
end
