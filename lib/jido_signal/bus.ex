defmodule Jido.Signal.Bus do
  @moduledoc """
  Provides ordered local publish and subscribe delivery for Signals.

  A normal subscription receives `{:signal, signal}` messages while its target
  process is alive.

  A durable subscription has a stable string ID. It receives one
  `{:signal, durable_id, recorded_signal}` message at a time. The target must
  acknowledge the record cursor before the Bus sends the next record. If the
  target exits, the Bus keeps the cursor and sends the unacknowledged record
  again when a new process attaches with the same durable ID.

  The Bus stores every record before it sends any message. Delivery is ordered
  and at least once. The Bus does not own retry timers, dead-letter queues,
  leases, or competing-consumer policy.

  `Jido.Signal.Bus.Store.Memory` is the only included store. Its state does not
  survive a Bus or VM restart. Applications that need restart durability can
  provide a store that implements `Jido.Signal.Bus.Store`.
  """

  use GenServer

  alias Jido.Signal
  alias Jido.Signal.Bus.RecordedSignal
  alias Jido.Signal.Bus.Store.Memory
  alias Jido.Signal.Bus.Subscriber
  alias Jido.Signal.Error
  alias Jido.Signal.ID
  alias Jido.Signal.Names
  alias Jido.Signal.Router
  alias Jido.Signal.Telemetry

  @type server ::
          pid() | atom() | binary() | {name :: atom() | binary(), registry :: module()}
  @type path :: Router.path()
  @type subscription_id :: String.t()
  @type durable_id :: String.t()

  @removed_start_options [
    :journal_adapter,
    :journal_adapter_opts,
    :journal_pid,
    :partition_count,
    :partition_rate_limit_per_sec,
    :partition_burst_size,
    :log_ttl_ms,
    :middleware,
    :middleware_timeout_ms
  ]

  @subscription_options [:target, :subscription_id, :durable, :start_from]

  @doc "Returns a child specification for a named Bus."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Starts a Bus linked to the caller.

  Options:

  - `:name` is required and sets the Registry name.
  - `:jido` selects an instance-scoped Registry.
  - `:store` selects a `Jido.Signal.Bus.Store` module.
  - `:store_opts` configures the selected store.
  - `:max_log_size` sets the memory-store record bound. The default is 100,000.

  Removed Journal, partition, and middleware options return a startup error.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, {name, opts}, name: via_tuple(name, opts))
  end

  @doc "Returns the Registry tuple for a Bus name."
  @spec via_tuple(server(), keyword()) :: {:via, Registry, {module(), String.t()}}
  def via_tuple(name_or_tuple, opts \\ [])

  def via_tuple({name, registry}, _opts) when is_atom(registry) do
    {:via, Registry, {registry, normalize_name(name)}}
  end

  def via_tuple(name, opts) do
    {:via, Registry, {registry(opts), normalize_name(name)}}
  end

  @doc "Finds a Bus by PID, name, or `{name, registry}` tuple."
  @spec whereis(server(), keyword()) :: {:ok, pid()} | {:error, :not_found}
  def whereis(server, opts \\ [])

  def whereis(pid, _opts) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :not_found}
  end

  def whereis({name, registry}, _opts) when is_atom(registry) do
    registry_lookup(registry, normalize_name(name))
  end

  def whereis(name, opts) do
    registry_lookup(registry(opts), normalize_name(name))
  end

  @doc """
  Adds a subscription for a signal-type path.

  The calling process is the default `:target`.

  Set `durable: "stable-id"` to keep a cursor when the target exits. A new
  durable subscription starts at the current cursor by default. Set
  `start_from: :origin` or a retained cursor to read older records.
  """
  @spec subscribe(server(), path(), keyword()) ::
          {:ok, subscription_id()} | {:error, term()}
  def subscribe(bus, path, opts \\ [])

  def subscribe(bus, path, opts) when is_list(opts) do
    opts = Keyword.put_new(opts, :target, self())

    with {:ok, result} <- bus_call(bus, {:subscribe, path, opts}) do
      result
    end
  end

  def subscribe(_bus, _path, _opts), do: {:error, :invalid_options}

  @doc """
  Detaches a subscription target.

  A normal subscription is removed. A durable subscription stays in the Store
  and can attach again through `subscribe/3` with the same durable ID.
  """
  @spec unsubscribe(server(), subscription_id(), keyword()) :: :ok | {:error, term()}
  def unsubscribe(bus, subscription_id, opts \\ []) do
    with {:ok, result} <- bus_call(bus, {:unsubscribe, subscription_id, opts}) do
      result
    end
  end

  @doc "Permanently removes a subscription and its durable cursor."
  @spec delete_subscription(server(), subscription_id()) :: :ok | {:error, term()}
  def delete_subscription(bus, subscription_id) do
    with {:ok, result} <- bus_call(bus, {:delete_subscription, subscription_id}) do
      result
    end
  end

  @doc "Publishes Signals after the Store accepts all records."
  @spec publish(server(), [Signal.t()]) ::
          {:ok, [RecordedSignal.t()]} | {:error, term()}
  def publish(_bus, []), do: {:ok, []}

  def publish(bus, signals) when is_list(signals) do
    with {:ok, result} <- bus_call(bus, {:publish, signals}) do
      result
    end
  end

  def publish(_bus, _signals), do: {:error, :invalid_signals}

  @doc """
  Reads retained records that match a signal-type path.

  Use `:after` for an exclusive cursor and `:limit` for a positive record count
  or `:infinity`.
  """
  @spec replay(server(), path(), keyword()) ::
          {:ok, [RecordedSignal.t()]} | {:error, term()}
  def replay(bus, path \\ "**", opts \\ []) do
    with {:ok, result} <- bus_call(bus, {:replay, path, opts}) do
      result
    end
  end

  @doc "Acknowledges the current record for a durable subscription."
  @spec ack(server(), durable_id(), non_neg_integer()) :: :ok | {:error, term()}
  def ack(bus, durable_id, cursor) do
    with {:ok, result} <- bus_call(bus, {:ack, durable_id, cursor}) do
      result
    end
  end

  @impl GenServer
  def init({name, opts}) do
    with :ok <- reject_removed_options(opts),
         {:ok, store_module, store_state} <- init_store(opts),
         {:ok, definitions} <- store_read(store_module, store_state, :list_subscriptions, []),
         {:ok, latest_cursor} <- store_read(store_module, store_state, :latest_cursor, []),
         :ok <- validate_latest_cursor(latest_cursor),
         {:ok, subscriptions, order, router} <- load_durable_subscriptions(definitions),
         :ok <- validate_loaded_cursors(subscriptions, latest_cursor) do
      {:ok,
       %{
         name: name,
         jido: Keyword.get(opts, :jido),
         router: router,
         subscriptions: subscriptions,
         subscription_order: order,
         monitors: %{},
         store_module: store_module,
         store_state: store_state,
         next_cursor: latest_cursor + 1
       }}
    else
      {:error, {:store_error, callback, reason}} ->
        {:stop, {:store_init_failed, callback, reason}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:subscribe, path, opts}, _from, state) do
    case subscribe_target(state, path, opts) do
      {:ok, id, state} -> {:reply, {:ok, id}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unsubscribe, subscription_id, opts}, _from, state) do
    case unsubscribe_target(state, subscription_id, opts) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete_subscription, subscription_id}, _from, state) do
    case delete_subscription_state(state, subscription_id) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:publish, signals}, _from, state) do
    started_at = System.monotonic_time()

    case do_publish(state, signals) do
      {:ok, records, state} ->
        Telemetry.execute(
          [:jido, :signal, :bus, :publish],
          %{count: length(records), duration: System.monotonic_time() - started_at},
          %{bus_name: state.name}
        )

        {:reply, {:ok, records}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:replay, path, opts}, _from, state) do
    {:reply, replay_records(state, path, opts), state}
  end

  def handle_call({:ack, durable_id, cursor}, {caller, _tag}, state) do
    case acknowledge(state, durable_id, cursor, caller) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor_ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {subscription_id, monitors} ->
        state = %{state | monitors: monitors}

        case Map.get(state.subscriptions, subscription_id) do
          nil ->
            {:noreply, state}

          %Subscriber{durable?: true} = subscriber ->
            subscriber = %{subscriber | target: nil, monitor_ref: nil, in_flight: nil}
            state = put_subscriber(state, subscriber)
            emit_subscription(:detached, state, subscriber)
            {:noreply, state}

          %Subscriber{} = subscriber ->
            {:noreply, remove_subscriber(state, subscriber, false)}
        end
    end
  end

  defp subscribe_target(state, path, opts) do
    with :ok <- validate_subscription_options(opts),
         :ok <- validate_path(path),
         {:ok, target} <- validate_target(Keyword.get(opts, :target)),
         {:ok, kind, id} <- subscription_identity(opts) do
      case kind do
        :ephemeral -> add_ephemeral(state, id, path, target)
        :durable -> attach_durable(state, id, path, target, opts)
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp validate_subscription_options(opts) do
    case Enum.find(Keyword.keys(opts), &(&1 not in @subscription_options)) do
      nil ->
        cond do
          Keyword.has_key?(opts, :durable) and Keyword.has_key?(opts, :subscription_id) ->
            {:error, {:conflicting_options, [:durable, :subscription_id]}}

          Keyword.has_key?(opts, :start_from) and not Keyword.has_key?(opts, :durable) ->
            {:error, {:requires_option, :start_from, :durable}}

          true ->
            :ok
        end

      option ->
        {:error, {:unsupported_option, option}}
    end
  end

  defp validate_path(path) do
    case Router.normalize({path, :subscription}) do
      {:ok, _routes} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_target(target) when is_pid(target) do
    if Process.alive?(target), do: {:ok, target}, else: {:error, :target_not_alive}
  end

  defp validate_target(_target), do: {:error, :invalid_target}

  defp subscription_identity(opts) do
    case Keyword.fetch(opts, :durable) do
      {:ok, id} when is_binary(id) and byte_size(id) > 0 ->
        {:ok, :durable, id}

      {:ok, _invalid} ->
        {:error, {:invalid_option, :durable}}

      :error ->
        case Keyword.get(opts, :subscription_id, ID.generate!()) do
          id when is_binary(id) and byte_size(id) > 0 -> {:ok, :ephemeral, id}
          _invalid -> {:error, {:invalid_option, :subscription_id}}
        end
    end
  end

  defp add_ephemeral(state, id, path, target) do
    if Map.has_key?(state.subscriptions, id) do
      {:error, :subscription_already_exists, state}
    else
      {monitor_ref, state} = monitor_target(state, id, target)

      subscriber = %Subscriber{
        id: id,
        path: path,
        durable?: false,
        target: target,
        monitor_ref: monitor_ref,
        cursor: 0,
        in_flight: nil,
        created_at: DateTime.utc_now()
      }

      state = insert_subscriber(state, subscriber)
      emit_subscription(:attached, state, subscriber)
      {:ok, id, state}
    end
  end

  defp attach_durable(state, id, path, target, opts) do
    case Map.get(state.subscriptions, id) do
      nil -> create_durable(state, id, path, target, opts)
      subscriber -> attach_existing_durable(state, subscriber, path, target)
    end
  end

  defp create_durable(state, id, path, target, opts) do
    with {:ok, cursor} <- initial_cursor(state, Keyword.get(opts, :start_from, :current)),
         created_at <- DateTime.utc_now(),
         definition <- durable_definition(id, path, cursor, created_at),
         {:ok, state} <- store_write(state, :put_subscription, [definition]) do
      {monitor_ref, state} = monitor_target(state, id, target)

      subscriber = %Subscriber{
        id: id,
        path: path,
        durable?: true,
        target: target,
        monitor_ref: monitor_ref,
        cursor: cursor,
        in_flight: nil,
        created_at: created_at
      }

      state = insert_subscriber(state, subscriber)
      emit_subscription(:attached, state, subscriber)

      case deliver_next(state, subscriber) do
        {:ok, state} ->
          {:ok, id, state}

        {:error, reason, state} ->
          emit_store_delivery_error(state, subscriber, reason)
          {:ok, id, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp attach_existing_durable(state, %Subscriber{durable?: false}, _path, _target) do
    {:error, :subscription_already_exists, state}
  end

  defp attach_existing_durable(state, subscriber, path, target) do
    if subscriber.path != path do
      {:error, :durable_subscription_conflict, state}
    else
      {state, subscriber} = drop_dead_target(state, subscriber)

      cond do
        subscriber.target == target ->
          {:ok, subscriber.id, state}

        is_pid(subscriber.target) ->
          {:error, :subscription_in_use, state}

        true ->
          {monitor_ref, state} = monitor_target(state, subscriber.id, target)
          subscriber = %{subscriber | target: target, monitor_ref: monitor_ref, in_flight: nil}
          state = put_subscriber(state, subscriber)
          emit_subscription(:attached, state, subscriber)

          case deliver_next(state, subscriber) do
            {:ok, state} ->
              {:ok, subscriber.id, state}

            {:error, reason, state} ->
              emit_store_delivery_error(state, subscriber, reason)
              {:ok, subscriber.id, state}
          end
      end
    end
  end

  defp drop_dead_target(state, %Subscriber{target: target} = subscriber) when is_pid(target) do
    if Process.alive?(target) do
      {state, subscriber}
    else
      state = demonitor_target(state, subscriber)
      {state, %{subscriber | target: nil, monitor_ref: nil, in_flight: nil}}
    end
  end

  defp drop_dead_target(state, subscriber), do: {state, subscriber}

  defp initial_cursor(_state, :origin), do: {:ok, 0}
  defp initial_cursor(state, :current), do: {:ok, state.next_cursor - 1}

  defp initial_cursor(state, cursor)
       when is_integer(cursor) and cursor >= 0 and cursor < state.next_cursor,
       do: {:ok, cursor}

  defp initial_cursor(_state, _start_from), do: {:error, {:invalid_option, :start_from}}

  defp unsubscribe_target(state, subscription_id, []) do
    case Map.get(state.subscriptions, subscription_id) do
      nil ->
        {:error, :subscription_not_found}

      %Subscriber{durable?: true} = subscriber ->
        state = demonitor_target(state, subscriber)
        subscriber = %{subscriber | target: nil, monitor_ref: nil, in_flight: nil}
        state = put_subscriber(state, subscriber)
        emit_subscription(:detached, state, subscriber)
        {:ok, state}

      %Subscriber{} = subscriber ->
        {:ok, remove_subscriber(state, subscriber)}
    end
  end

  defp unsubscribe_target(_state, _subscription_id, _opts), do: {:error, :invalid_options}

  defp delete_subscription_state(state, subscription_id) do
    case Map.get(state.subscriptions, subscription_id) do
      nil ->
        {:error, :subscription_not_found}

      %Subscriber{durable?: true} = subscriber ->
        with {:ok, state} <- store_write(state, :delete_subscription, [subscription_id]) do
          {:ok, remove_subscriber(state, subscriber)}
        end

      %Subscriber{} = subscriber ->
        {:ok, remove_subscriber(state, subscriber)}
    end
  end

  defp do_publish(state, signals) do
    with :ok <- validate_signals(signals),
         {stored_records, entries, next_cursor} <- build_records(signals, state.next_cursor),
         {:ok, state} <- store_write(state, :append, [stored_records]) do
      state = %{state | next_cursor: next_cursor}
      state = Enum.reduce(entries, state, &deliver_published_entry/2)
      {:ok, Enum.map(entries, &elem(&1, 2)), state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp validate_signals(signals) do
    if Enum.all?(signals, &match?(%Signal{}, &1)) do
      :ok
    else
      {:error, Error.validation_error("Signals must be Signal structs", %{field: :signals})}
    end
  end

  defp build_records(signals, start_cursor) do
    {entries, next_cursor} =
      Enum.map_reduce(signals, start_cursor, fn signal, cursor ->
        created_at = DateTime.utc_now()

        stored = %{
          "format_version" => 1,
          "id" => ID.generate!(),
          "cursor" => cursor,
          "type" => signal.type,
          "created_at" => DateTime.to_iso8601(created_at),
          "signal" => Signal.to_map(signal)
        }

        public = %RecordedSignal{
          id: stored["id"],
          cursor: cursor,
          type: signal.type,
          created_at: created_at,
          signal: signal
        }

        {{stored, signal, public}, cursor + 1}
      end)

    {Enum.map(entries, &elem(&1, 0)), entries, next_cursor}
  end

  defp deliver_published_entry({_stored, signal, _public}, state) do
    case Router.route(state.router, signal) do
      {:ok, subscription_ids} ->
        Enum.reduce(subscription_ids, state, &deliver_to_subscription(&1, signal, &2))

      {:error, _no_match} ->
        state
    end
  end

  defp deliver_to_subscription(subscription_id, signal, state) do
    case Map.fetch!(state.subscriptions, subscription_id) do
      %Subscriber{durable?: true} = subscriber ->
        case deliver_next(state, subscriber) do
          {:ok, state} -> state
          {:error, reason, state} -> emit_delivery_error(state, subscriber, signal, reason)
        end

      %Subscriber{target: target} = subscriber ->
        send(target, {:signal, signal})
        emit_delivery(state, subscriber, signal, nil)
        state
    end
  end

  defp deliver_next(state, %Subscriber{target: nil}), do: {:ok, state}

  defp deliver_next(state, %Subscriber{in_flight: cursor}) when is_integer(cursor),
    do: {:ok, state}

  defp deliver_next(state, %Subscriber{} = subscriber) do
    with {:ok, records} <-
           store_read(state, :read, [
             [after_cursor: subscriber.cursor, path: subscriber.path, limit: 1]
           ]),
         true <- is_list(records),
         record when not is_nil(record) <- List.first(records),
         {:ok, public} <- record_to_public(record) do
      send(subscriber.target, {:signal, subscriber.id, public})
      subscriber = %{subscriber | in_flight: public.cursor}
      state = put_subscriber(state, subscriber)
      emit_delivery(state, subscriber, public.signal, public.cursor)
      {:ok, state}
    else
      nil -> {:ok, state}
      false -> {:error, :invalid_store_records, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp acknowledge(state, durable_id, cursor, caller)
       when is_integer(cursor) and cursor >= 0 do
    case Map.get(state.subscriptions, durable_id) do
      nil ->
        {:error, :subscription_not_found, state}

      %Subscriber{durable?: false} ->
        {:error, :subscription_not_durable, state}

      %Subscriber{target: target} when target != caller ->
        {:error, :not_subscription_owner, state}

      %Subscriber{in_flight: nil} ->
        {:error, :no_record_in_flight, state}

      %Subscriber{in_flight: expected} when expected != cursor ->
        {:error, {:unexpected_cursor, expected}, state}

      %Subscriber{} = subscriber ->
        definition = durable_definition(subscriber, cursor)

        case store_write(state, :put_subscription, [definition]) do
          {:ok, state} ->
            subscriber = %{subscriber | cursor: cursor, in_flight: nil}
            state = put_subscriber(state, subscriber)

            Telemetry.execute(
              [:jido, :signal, :bus, :ack],
              %{cursor: cursor},
              %{bus_name: state.name, subscription_id: durable_id}
            )

            case deliver_next(state, subscriber) do
              {:ok, state} ->
                {:ok, state}

              {:error, reason, state} ->
                emit_store_delivery_error(state, subscriber, reason)
                {:ok, state}
            end

          {:error, reason} ->
            {:error, reason, state}
        end
    end
  end

  defp acknowledge(state, _durable_id, _cursor, _caller),
    do: {:error, :invalid_cursor, state}

  defp replay_records(state, path, opts) when is_list(opts) do
    after_cursor = Keyword.get(opts, :after, 0)
    limit = Keyword.get(opts, :limit, :infinity)

    with :ok <- validate_path(path),
         :ok <- validate_replay_options(opts, after_cursor, limit),
         {:ok, records} <-
           store_read(state, :read, [[after_cursor: after_cursor, path: path, limit: limit]]),
         true <- is_list(records),
         {:ok, public} <- decode_records(records) do
      {:ok, public}
    else
      false -> {:error, :invalid_store_records}
      error -> error
    end
  end

  defp replay_records(_state, _path, _opts), do: {:error, :invalid_options}

  defp validate_replay_options(opts, after_cursor, limit) do
    unsupported = Enum.find(Keyword.keys(opts), &(&1 not in [:after, :limit]))

    cond do
      unsupported ->
        {:error, {:unsupported_option, unsupported}}

      not (is_integer(after_cursor) and after_cursor >= 0) ->
        {:error, {:invalid_option, :after}}

      limit != :infinity and not (is_integer(limit) and limit > 0) ->
        {:error, {:invalid_option, :limit}}

      true ->
        :ok
    end
  end

  defp decode_records(records) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, decoded} ->
      case record_to_public(record) do
        {:ok, public} -> {:cont, {:ok, [public | decoded]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp record_to_public(%{
         "format_version" => 1,
         "id" => id,
         "cursor" => cursor,
         "type" => type,
         "created_at" => created_at,
         "signal" => signal_map
       })
       when is_binary(created_at) and is_map(signal_map) do
    with true <- is_binary(id),
         true <- is_integer(cursor) and cursor > 0,
         true <- is_binary(type),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(created_at),
         {:ok, signal} <- Signal.from_map(signal_map) do
      {:ok,
       %RecordedSignal{
         id: id,
         cursor: cursor,
         type: type,
         created_at: datetime,
         signal: signal
       }}
    else
      _invalid -> {:error, :invalid_store_record}
    end
  end

  defp record_to_public(_record), do: {:error, :unsupported_store_record}

  defp init_store(opts) do
    store_module = Keyword.get(opts, :store, Memory)

    store_opts = Keyword.get(opts, :store_opts, [])

    store_opts =
      if store_module == Memory do
        Keyword.put_new(store_opts, :max_records, Keyword.get(opts, :max_log_size, 100_000))
      else
        store_opts
      end

    case safe_apply(store_module, :init, [store_opts]) do
      {:ok, store_state} -> {:ok, store_module, store_state}
      {:error, reason} -> {:error, {:store_init_failed, reason}}
      other -> {:error, {:store_init_failed, {:invalid_return, other}}}
    end
  end

  defp validate_latest_cursor(cursor) when is_integer(cursor) and cursor >= 0, do: :ok
  defp validate_latest_cursor(_cursor), do: {:error, :invalid_store_cursor}

  defp validate_loaded_cursors(subscriptions, latest_cursor) do
    if Enum.all?(subscriptions, fn {_id, subscriber} -> subscriber.cursor <= latest_cursor end),
      do: :ok,
      else: {:error, :invalid_store_subscription_cursor}
  end

  defp load_durable_subscriptions(definitions) when is_list(definitions) do
    Enum.reduce_while(definitions, {:ok, %{}, [], Router.new!()}, fn definition,
                                                                     {:ok, subscriptions, order,
                                                                      router} ->
      with {:ok, subscriber} <- subscriber_from_definition(definition),
           false <- Map.has_key?(subscriptions, subscriber.id),
           {:ok, router} <- Router.add(router, {subscriber.path, subscriber.id}) do
        {:cont,
         {:ok, Map.put(subscriptions, subscriber.id, subscriber), order ++ [subscriber.id],
          router}}
      else
        _invalid -> {:halt, {:error, :invalid_store_subscription}}
      end
    end)
  end

  defp load_durable_subscriptions(_definitions), do: {:error, :invalid_store_subscriptions}

  defp subscriber_from_definition(%{
         "format_version" => 1,
         "id" => id,
         "path" => path,
         "cursor" => cursor,
         "created_at" => created_at
       })
       when is_binary(id) and byte_size(id) > 0 and is_binary(path) and is_integer(cursor) and
              cursor >= 0 and is_binary(created_at) do
    with :ok <- validate_path(path),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(created_at) do
      {:ok,
       %Subscriber{
         id: id,
         path: path,
         durable?: true,
         target: nil,
         monitor_ref: nil,
         cursor: cursor,
         in_flight: nil,
         created_at: datetime
       }}
    else
      _invalid -> {:error, :invalid_store_subscription}
    end
  end

  defp subscriber_from_definition(_definition), do: {:error, :unsupported_store_subscription}

  defp durable_definition(%Subscriber{} = subscriber, cursor) do
    durable_definition(subscriber.id, subscriber.path, cursor, subscriber.created_at)
  end

  defp durable_definition(id, path, cursor, created_at) do
    %{
      "format_version" => 1,
      "id" => id,
      "path" => path,
      "cursor" => cursor,
      "created_at" => DateTime.to_iso8601(created_at)
    }
  end

  defp store_read(state, callback, args) do
    store_read(state.store_module, state.store_state, callback, args)
  end

  defp store_read(store_module, store_state, callback, args) do
    case safe_apply(store_module, callback, args ++ [store_state]) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, {:store_error, callback, reason}}
      other -> {:error, {:store_error, callback, {:invalid_return, other}}}
    end
  end

  defp store_write(state, callback, args) do
    case safe_apply(state.store_module, callback, args ++ [state.store_state]) do
      {:ok, store_state} -> {:ok, %{state | store_state: store_state}}
      {:error, reason} -> {:error, {:store_error, callback, reason}}
      other -> {:error, {:store_error, callback, {:invalid_return, other}}}
    end
  end

  defp safe_apply(module, callback, args) do
    apply(module, callback, args)
  rescue
    error -> {:error, {:exception, error}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp monitor_target(state, subscription_id, target) do
    monitor_ref = Process.monitor(target)
    {monitor_ref, %{state | monitors: Map.put(state.monitors, monitor_ref, subscription_id)}}
  end

  defp demonitor_target(state, %Subscriber{monitor_ref: nil}), do: state

  defp demonitor_target(state, %Subscriber{monitor_ref: monitor_ref}) do
    Process.demonitor(monitor_ref, [:flush])
    %{state | monitors: Map.delete(state.monitors, monitor_ref)}
  end

  defp insert_subscriber(state, subscriber) do
    {:ok, router} = Router.add(state.router, {subscriber.path, subscriber.id})

    %{
      state
      | subscriptions: Map.put(state.subscriptions, subscriber.id, subscriber),
        subscription_order: state.subscription_order ++ [subscriber.id],
        router: router
    }
  end

  defp put_subscriber(state, subscriber) do
    %{state | subscriptions: Map.put(state.subscriptions, subscriber.id, subscriber)}
  end

  defp remove_subscriber(state, subscriber, demonitor? \\ true) do
    state = if demonitor?, do: demonitor_target(state, subscriber), else: state
    subscriptions = Map.delete(state.subscriptions, subscriber.id)
    order = Enum.reject(state.subscription_order, &(&1 == subscriber.id))

    routes =
      Enum.map(order, fn id ->
        current = Map.fetch!(subscriptions, id)
        {current.path, current.id}
      end)

    %{
      state
      | subscriptions: subscriptions,
        subscription_order: order,
        router: Router.new!(routes)
    }
  end

  defp emit_subscription(event, state, subscriber) do
    Telemetry.execute(
      [:jido, :signal, :bus, :subscription, event],
      %{system_time: System.system_time()},
      %{
        bus_name: state.name,
        subscription_id: subscriber.id,
        subscription_path: subscriber.path,
        durable: subscriber.durable?
      }
    )
  end

  defp emit_delivery(state, subscriber, signal, cursor) do
    Telemetry.execute(
      [:jido, :signal, :bus, :deliver],
      %{system_time: System.system_time()},
      %{
        bus_name: state.name,
        subscription_id: subscriber.id,
        subscription_path: subscriber.path,
        durable: subscriber.durable?,
        cursor: cursor,
        signal_id: signal.id,
        signal_type: signal.type
      },
      signal
    )
  end

  defp emit_delivery_error(state, subscriber, signal, reason) do
    Telemetry.execute(
      [:jido, :signal, :bus, :delivery_error],
      %{system_time: System.system_time()},
      %{
        bus_name: state.name,
        subscription_id: subscriber.id,
        signal_id: signal.id,
        signal_type: signal.type,
        reason: reason
      },
      signal
    )

    state
  end

  defp emit_store_delivery_error(state, subscriber, reason) do
    Telemetry.execute(
      [:jido, :signal, :bus, :delivery_error],
      %{system_time: System.system_time()},
      %{
        bus_name: state.name,
        subscription_id: subscriber.id,
        reason: reason
      }
    )
  end

  defp reject_removed_options(opts) do
    case Enum.find(@removed_start_options, &Keyword.has_key?(opts, &1)) do
      nil -> :ok
      option -> {:error, {:unsupported_option, option}}
    end
  end

  defp registry(opts) do
    case Keyword.get(opts, :jido) do
      nil -> Keyword.get(opts, :registry, Jido.Signal.Registry)
      _instance -> Names.registry(opts)
    end
  end

  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_name(name) when is_binary(name), do: name

  defp registry_lookup(registry, name) do
    case Registry.lookup(registry, name) do
      [{pid, _value} | _rest] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  catch
    :exit, _reason -> {:error, :not_found}
  end

  defp bus_call(bus, message) do
    {:ok, GenServer.call(bus_call_target(bus), message)}
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, :noproc -> {:error, :not_found}
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, :timeout -> {:error, :timeout}
  end

  defp bus_call_target(pid) when is_pid(pid), do: pid
  defp bus_call_target({name, registry}) when is_atom(registry), do: via_tuple({name, registry})

  defp bus_call_target(name) when is_atom(name) or is_binary(name),
    do: via_tuple(name)
end
