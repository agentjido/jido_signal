defmodule Jido.Signal.Bus do
  @moduledoc """
  Provides ordered, local publish and subscribe delivery for Signals.

  The Bus keeps its implementation state private. Its default memory store keeps
  a bounded replay log, persistent-subscription checkpoints, and dead-letter
  entries. Set `:store` to a module that implements `Jido.Signal.Bus.Store` when
  retained data must survive a Bus restart.

  Persistent subscriptions use at-least-once delivery. Acknowledgements advance
  a numeric cursor only across a continuous set of handled records. Delivery
  errors go to the Bus dead-letter queue without an internal retry loop.
  """

  use GenServer

  alias Jido.Signal
  alias Jido.Signal.Bus.MiddlewarePipeline
  alias Jido.Signal.Bus.RecordedSignal
  alias Jido.Signal.Bus.Store.Memory
  alias Jido.Signal.Bus.Subscriber
  alias Jido.Signal.Dispatch
  alias Jido.Signal.Error
  alias Jido.Signal.ID
  alias Jido.Signal.Router
  alias Jido.Signal.Telemetry
  alias Jido.Signal.Util

  @type server ::
          pid() | atom() | binary() | {name :: atom() | binary(), registry :: module()}
  @type path :: Router.path()
  @type subscription_id :: String.t()

  @removed_options [
    :journal_adapter,
    :journal_adapter_opts,
    :journal_pid,
    :partition_count,
    :partition_rate_limit_per_sec,
    :partition_burst_size,
    :log_ttl_ms
  ]

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

  Required option:

  - `:name` is the Bus registration name.

  Supported options:

  - `:jido` selects an instance-scoped registry.
  - `:middleware` is a list of `{module, options}` values.
  - `:middleware_timeout_ms` sets each middleware callback timeout.
  - `:store` selects a `Jido.Signal.Bus.Store` implementation.
  - `:store_opts` configures the selected store.
  - `:max_log_size` sets the default memory-store bound.

  Removed Journal and partition options return a startup error.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, {name, opts}, name: via_tuple(name, opts))
  end

  defdelegate via_tuple(name, opts \\ []), to: Util
  defdelegate whereis(server, opts \\ []), to: Util

  @doc """
  Adds a subscription for a signal-type path.

  The default target is the calling process. Use `:persistent?` for retained
  acknowledgements and reconnect. The v2 `:persistent` alias is also accepted.
  """
  @spec subscribe(server(), path(), keyword()) ::
          {:ok, subscription_id()} | {:error, term()}
  def subscribe(bus, path, opts \\ []) do
    opts = normalize_subscription_options(opts)

    with {:ok, result} <- bus_call(bus, {:subscribe, path, opts}) do
      result
    end
  end

  @doc "Removes a subscription."
  @spec unsubscribe(server(), subscription_id(), keyword()) :: :ok | {:error, term()}
  def unsubscribe(bus, subscription_id, opts \\ []) do
    with {:ok, result} <- bus_call(bus, {:unsubscribe, subscription_id, opts}) do
      result
    end
  end

  @doc "Publishes a list of Signals and returns their replay records."
  @spec publish(server(), [Signal.t()]) ::
          {:ok, [RecordedSignal.t()]} | {:error, term()}
  def publish(_bus, []), do: {:ok, []}

  def publish(bus, signals) when is_list(signals) do
    with {:ok, result} <- bus_call(bus, {:publish, signals}) do
      result
    end
  end

  def publish(_bus, _signals), do: {:error, :invalid_signals}

  @doc "Replays retained records that match a signal-type path."
  @spec replay(server(), path(), non_neg_integer(), keyword()) ::
          {:ok, [RecordedSignal.t()]} | {:error, term()}
  def replay(bus, path \\ "*", start_timestamp \\ 0, opts \\ []) do
    with {:ok, result} <- bus_call(bus, {:replay, path, start_timestamp, opts}) do
      result
    end
  end

  @doc "Acknowledges one or more record IDs for a persistent subscription."
  @spec ack(server(), subscription_id(), String.t() | [String.t()] | integer()) ::
          :ok | {:error, term()}
  def ack(bus, subscription_id, record_ids) do
    with {:ok, result} <- bus_call(bus, {:ack, subscription_id, record_ids}) do
      result
    end
  end

  @doc "Reconnects a process to a persistent subscription."
  @spec reconnect(server(), subscription_id(), pid()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def reconnect(bus, subscription_id, client_pid) do
    with {:ok, result} <- bus_call(bus, {:reconnect, subscription_id, client_pid}) do
      result
    end
  end

  @doc "Lists dead-letter entries for a subscription."
  @spec dlq_entries(server(), subscription_id()) :: {:ok, [map()]} | {:error, term()}
  def dlq_entries(bus, subscription_id) do
    with {:ok, result} <- bus_call(bus, {:dlq_entries, subscription_id}) do
      result
    end
  end

  @doc "Attempts delivery for dead-letter entries."
  @spec redrive_dlq(server(), subscription_id(), keyword()) ::
          {:ok, %{succeeded: non_neg_integer(), failed: non_neg_integer()}} | {:error, term()}
  def redrive_dlq(bus, subscription_id, opts \\ []) do
    with {:ok, result} <- bus_call(bus, {:redrive_dlq, subscription_id, opts}) do
      result
    end
  end

  @doc "Deletes all dead-letter entries for a subscription."
  @spec clear_dlq(server(), subscription_id()) :: :ok | {:error, term()}
  def clear_dlq(bus, subscription_id) do
    with {:ok, result} <- bus_call(bus, {:clear_dlq, subscription_id}) do
      result
    end
  end

  @impl GenServer
  def init({name, opts}) do
    with :ok <- reject_removed_options(opts),
         {:ok, middleware} <- init_middleware(opts),
         {:ok, store_module, store_state} <- init_store(opts) do
      {:ok,
       %{
         name: name,
         jido: Keyword.get(opts, :jido),
         subscriptions: %{},
         subscription_order: [],
         monitors: %{},
         middleware: middleware,
         middleware_timeout_ms: Keyword.get(opts, :middleware_timeout_ms, 100),
         store_module: store_module,
         store_state: store_state,
         next_cursor: next_cursor(store_module, store_state)
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:subscribe, path, opts}, _from, state) do
    subscription_id = Keyword.get(opts, :subscription_id, ID.generate!())

    with :ok <- validate_new_subscription(state, subscription_id, path),
         {:ok, dispatch} <- Dispatch.validate_opts(Keyword.fetch!(opts, :dispatch)),
         {:ok, checkpoint} <- initial_checkpoint(state, subscription_id, opts),
         {:ok, subscriber, state} <-
           build_subscriber(state, subscription_id, path, dispatch, checkpoint, opts),
         {:ok, state} <- add_and_replay_subscriber(state, subscriber, checkpoint) do
      {:reply, {:ok, subscription_id}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unsubscribe, subscription_id, opts}, _from, state) do
    case Map.fetch(state.subscriptions, subscription_id) do
      :error ->
        {:reply, {:error, :subscription_not_found}, state}

      {:ok, subscriber} ->
        state = remove_subscriber(state, subscriber)

        case maybe_delete_retained_subscription(state, subscriber, opts) do
          {:ok, state} -> {:reply, :ok, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:publish, signals}, _from, state) do
    case do_publish(state, signals) do
      {:ok, records, state} -> {:reply, {:ok, records}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:replay, path, start_timestamp, opts}, _from, state) do
    reply = replay_records(state, path, start_timestamp, opts)
    {:reply, reply, state}
  end

  def handle_call({:ack, subscription_id, record_ids}, _from, state) do
    case acknowledge(state, subscription_id, record_ids) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reconnect, subscription_id, client_pid}, _from, state) do
    case reconnect_subscriber(state, subscription_id, client_pid) do
      {:ok, checkpoint, state} -> {:reply, {:ok, checkpoint}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:dlq_entries, subscription_id}, _from, state) do
    reply =
      with {:ok, entries} <- store_read(state, :list_dlq, [subscription_id]) do
        decode_dlq_entries(entries)
      end

    {:reply, reply, state}
  end

  def handle_call({:redrive_dlq, subscription_id, opts}, _from, state) do
    case redrive(state, subscription_id, opts) do
      {:ok, result, state} -> {:reply, {:ok, result}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:clear_dlq, subscription_id}, _from, state) do
    case store_write(state, :clear_dlq, [subscription_id]) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor_ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {subscription_id, monitors} ->
        subscriber = Map.get(state.subscriptions, subscription_id)
        state = %{state | monitors: monitors}

        cond do
          is_nil(subscriber) ->
            {:noreply, state}

          subscriber.persistent? ->
            subscriber = %{
              subscriber
              | disconnected?: true,
                client_pid: nil,
                monitor_ref: nil
            }

            {:noreply, put_subscriber(state, subscriber)}

          true ->
            {:noreply, remove_subscriber(state, subscriber, false)}
        end
    end
  end

  defp normalize_subscription_options(opts) do
    opts =
      cond do
        Keyword.has_key?(opts, :persistent?) ->
          Keyword.delete(opts, :persistent)

        Keyword.has_key?(opts, :persistent) ->
          opts
          |> Keyword.put(:persistent?, Keyword.fetch!(opts, :persistent))
          |> Keyword.delete(:persistent)

        true ->
          opts
      end

    dispatch =
      case Keyword.get(opts, :dispatch) do
        nil -> {:pid, target: self(), delivery_mode: :async}
        {:pid, pid_opts} -> {:pid, Keyword.put(pid_opts, :delivery_mode, :async)}
        target -> target
      end

    Keyword.put(opts, :dispatch, dispatch)
  end

  defp reject_removed_options(opts) do
    case Enum.find(@removed_options, &Keyword.has_key?(opts, &1)) do
      nil -> :ok
      option -> {:error, {:unsupported_option, option}}
    end
  end

  defp init_middleware(opts) do
    case MiddlewarePipeline.init_middleware(Keyword.get(opts, :middleware, [])) do
      {:ok, middleware} -> {:ok, middleware}
      {:error, reason} -> {:error, {:middleware_init_failed, reason}}
    end
  end

  defp init_store(opts) do
    store_module = Keyword.get(opts, :store, Memory)

    store_opts =
      opts
      |> Keyword.get(:store_opts, [])
      |> Keyword.put_new(:max_records, Keyword.get(opts, :max_log_size, 100_000))

    case safe_apply(store_module, :init, [store_opts]) do
      {:ok, store_state} -> {:ok, store_module, store_state}
      {:error, reason} -> {:error, {:store_init_failed, reason}}
      other -> {:error, {:store_init_failed, {:invalid_return, other}}}
    end
  end

  defp next_cursor(store_module, store_state) do
    case safe_apply(store_module, :read, [[after_cursor: -1], store_state]) do
      {:ok, []} ->
        1

      {:ok, records} ->
        records |> Enum.map(&Map.fetch!(&1, "cursor")) |> Enum.max() |> Kernel.+(1)

      _error ->
        1
    end
  end

  defp validate_new_subscription(state, subscription_id, path) do
    if Map.has_key?(state.subscriptions, subscription_id) do
      {:error, :subscription_already_exists}
    else
      case Router.normalize({path, :subscription}) do
        {:ok, _routes} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp initial_checkpoint(state, subscription_id, opts) do
    persistent? = Keyword.get(opts, :persistent?, false)

    if persistent? do
      persistent_initial_checkpoint(state, subscription_id, opts)
    else
      {:ok, state.next_cursor - 1}
    end
  end

  defp persistent_initial_checkpoint(state, subscription_id, opts) do
    with {:ok, stored} <-
           store_read(state, :get_checkpoint, [checkpoint_key(state, subscription_id)]) do
      normalize_initial_checkpoint(stored, Keyword.get(opts, :start_from, :origin), state)
    end
  end

  defp normalize_initial_checkpoint(cursor, _start, _state) when is_integer(cursor),
    do: {:ok, cursor}

  defp normalize_initial_checkpoint(nil, :origin, _state), do: {:ok, 0}
  defp normalize_initial_checkpoint(nil, :current, state), do: {:ok, state.next_cursor - 1}

  defp normalize_initial_checkpoint(nil, cursor, _state)
       when is_integer(cursor) and cursor >= 0,
       do: {:ok, cursor}

  defp normalize_initial_checkpoint(_stored, _start, _state),
    do: {:error, {:invalid_option, :start_from}}

  defp build_subscriber(state, id, path, dispatch, checkpoint, opts) do
    client_pid = dispatch_pid(dispatch)
    {monitor_ref, state} = monitor_subscriber(state, id, client_pid)

    subscriber = %Subscriber{
      id: id,
      path: path,
      dispatch: dispatch,
      persistent?: Keyword.get(opts, :persistent?, false),
      disconnected?: false,
      client_pid: client_pid,
      monitor_ref: monitor_ref,
      created_at: DateTime.utc_now(),
      pending: %{},
      last_seen_cursor: checkpoint
    }

    {:ok, subscriber, state}
  end

  defp add_and_replay_subscriber(state, subscriber, checkpoint) do
    if subscriber.persistent? do
      add_and_replay_persistent_subscriber(state, subscriber, checkpoint)
    else
      {:ok, insert_subscriber(state, subscriber)}
    end
  end

  defp add_and_replay_persistent_subscriber(state, subscriber, checkpoint) do
    with {:ok, state} <-
           store_write(state, :put_checkpoint, [
             checkpoint_key(state, subscriber.id),
             checkpoint
           ]),
         state <- insert_subscriber(state, subscriber),
         {:ok, records} <- store_read(state, :read, [[after_cursor: checkpoint]]) do
      records
      |> Enum.filter(&Router.matches?(record_type(&1), subscriber.path))
      |> deliver_records_to_subscriber(state, subscriber.id)
      |> normalize_delivery_result()
    end
  end

  defp normalize_delivery_result({:ok, state}), do: {:ok, state}
  defp normalize_delivery_result({:error, reason, _state}), do: {:error, reason}

  defp do_publish(state, signals) do
    with :ok <- validate_signals(signals),
         {:ok, signals, middleware} <- before_publish(state, signals),
         :ok <- validate_signals(signals),
         {records, next_cursor} <- build_records(signals, state.next_cursor),
         {:ok, state} <- store_write(%{state | middleware: middleware}, :append, [records]),
         state <- %{state | next_cursor: next_cursor},
         {:ok, state} <- dispatch_published_records(state, records) do
      state = %{
        state
        | middleware:
            MiddlewarePipeline.after_publish(
              state.middleware,
              signals,
              middleware_context(state),
              state.middleware_timeout_ms
            ),
          next_cursor: next_cursor
      }

      {:ok, Enum.map(records, &record_to_public!/1), state}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, reason, failed_state} -> {:error, reason, failed_state}
    end
  end

  defp validate_signals(signals) do
    if Enum.all?(signals, &match?(%Signal{}, &1)) do
      :ok
    else
      {:error, Error.validation_error("Signals must be Signal structs", %{field: :signals})}
    end
  end

  defp before_publish(state, signals) do
    MiddlewarePipeline.before_publish(
      state.middleware,
      signals,
      middleware_context(state),
      state.middleware_timeout_ms
    )
  end

  defp build_records(signals, start_cursor) do
    {records, next_cursor} =
      Enum.map_reduce(signals, start_cursor, fn signal, cursor ->
        now = DateTime.utc_now()

        record = %{
          "format_version" => 1,
          "id" => ID.generate!(),
          "cursor" => cursor,
          "type" => signal.type,
          "created_at" => DateTime.to_iso8601(now),
          "timestamp_ms" => DateTime.to_unix(now, :millisecond),
          "signal" => Signal.to_map(signal)
        }

        {record, cursor + 1}
      end)

    {records, next_cursor}
  end

  defp dispatch_published_records(state, records) do
    Enum.reduce_while(records, {:ok, state}, fn record, {:ok, current_state} ->
      case dispatch_record(current_state, record) do
        {:ok, new_state} -> {:cont, {:ok, new_state}}
        {:error, reason, new_state} -> {:halt, {:error, reason, new_state}}
      end
    end)
  end

  defp dispatch_record(state, record) do
    Enum.reduce_while(state.subscription_order, {:ok, state}, fn subscription_id,
                                                                 {:ok, current_state} ->
      case maybe_deliver_record(current_state, record, subscription_id) do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:error, reason, next_state} -> {:halt, {:error, reason, next_state}}
      end
    end)
  end

  defp maybe_deliver_record(state, record, subscription_id) do
    subscriber = Map.get(state.subscriptions, subscription_id)

    if subscriber && Router.matches?(record_type(record), subscriber.path),
      do: deliver_record_to_subscriber(state, record, subscriber),
      else: {:ok, state}
  end

  defp deliver_records_to_subscriber(records, state, subscription_id) do
    Enum.reduce_while(records, {:ok, state}, fn record, {:ok, current_state} ->
      subscriber = Map.fetch!(current_state.subscriptions, subscription_id)

      case deliver_record_to_subscriber(current_state, record, subscriber) do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:error, reason, next_state} -> {:halt, {:error, reason, next_state}}
      end
    end)
  end

  defp deliver_record_to_subscriber(state, record, subscriber) do
    cursor = Map.fetch!(record, "cursor")
    subscriber = %{subscriber | last_seen_cursor: max(subscriber.last_seen_cursor, cursor)}

    if subscriber.persistent? && subscriber.disconnected? do
      pending = Map.put(subscriber.pending, Map.fetch!(record, "id"), cursor)
      {:ok, put_subscriber(state, %{subscriber | pending: pending})}
    else
      case run_dispatch(state, record_to_public!(record).signal, subscriber) do
        {:ok, state} -> handle_delivery_success(state, record, subscriber)
        {:skip, state} -> handle_delivery_skip(state, subscriber)
        {:error, reason, state} -> handle_delivery_error(state, record, subscriber, reason)
      end
    end
  end

  defp run_dispatch(state, signal, subscriber) do
    emit_dispatch(:before_dispatch, state, signal, subscriber, %{outcome: :start})

    case MiddlewarePipeline.before_dispatch(
           state.middleware,
           signal,
           subscriber,
           middleware_context(state),
           state.middleware_timeout_ms
         ) do
      {:ok, signal, middleware} ->
        result = Dispatch.dispatch(signal, subscriber.dispatch)
        state = %{state | middleware: middleware}

        middleware =
          MiddlewarePipeline.after_dispatch(
            state.middleware,
            signal,
            subscriber,
            result,
            middleware_context(state),
            state.middleware_timeout_ms
          )

        state = %{state | middleware: middleware}

        case result do
          :ok ->
            emit_dispatch(:after_dispatch, state, signal, subscriber, %{dispatch_result: :ok})
            {:ok, state}

          {:error, reason} ->
            emit_dispatch(:dispatch_error, state, signal, subscriber, %{
              outcome: :error,
              error: reason
            })

            {:error, reason, state}
        end

      :skip ->
        emit_dispatch(:dispatch_skipped, state, signal, subscriber, %{
          outcome: :skipped,
          reason: :middleware_skip
        })

        {:skip, state}

      {:error, reason} ->
        emit_dispatch(:dispatch_error, state, signal, subscriber, %{
          outcome: :error,
          error: reason
        })

        {:error, reason, state}
    end
  end

  defp handle_delivery_success(state, record, subscriber) do
    if subscriber.persistent? do
      pending =
        Map.put(subscriber.pending, Map.fetch!(record, "id"), Map.fetch!(record, "cursor"))

      {:ok, put_subscriber(state, %{subscriber | pending: pending})}
    else
      {:ok, put_subscriber(state, subscriber)}
    end
  end

  defp handle_delivery_skip(state, subscriber) do
    if subscriber.persistent? do
      persist_subscriber_checkpoint(state, subscriber)
    else
      {:ok, put_subscriber(state, subscriber)}
    end
  end

  defp handle_delivery_error(state, record, subscriber, reason) do
    if subscriber.persistent? do
      move_failed_delivery_to_dlq(state, record, subscriber, reason)
    else
      {:ok, put_subscriber(state, subscriber)}
    end
  end

  defp move_failed_delivery_to_dlq(state, record, subscriber, reason) do
    entry = dlq_store_entry(subscriber.id, record, reason)

    case store_write(state, :put_dlq, [subscriber.id, entry]) do
      {:ok, state} -> persist_failed_delivery_checkpoint(state, subscriber)
      {:error, store_reason} -> {:error, store_reason, state}
    end
  end

  defp persist_failed_delivery_checkpoint(state, subscriber) do
    case persist_subscriber_checkpoint(state, subscriber) do
      {:ok, state} -> {:ok, state}
      {:error, store_reason} -> {:error, store_reason, state}
    end
  end

  defp persist_subscriber_checkpoint(state, subscriber) do
    checkpoint = continuous_checkpoint(subscriber)

    with {:ok, state} <-
           store_write(state, :put_checkpoint, [checkpoint_key(state, subscriber.id), checkpoint]) do
      {:ok, put_subscriber(state, subscriber)}
    end
  end

  defp continuous_checkpoint(%Subscriber{pending: pending, last_seen_cursor: last_seen}) do
    case Map.values(pending) do
      [] -> last_seen
      cursors -> max(Enum.min(cursors) - 1, 0)
    end
  end

  defp replay_records(state, path, start_timestamp, opts)
       when is_integer(start_timestamp) and start_timestamp >= 0 do
    batch_size = Keyword.get(opts, :batch_size, :infinity)

    with {:ok, _routes} <- Router.normalize({path, :replay}),
         :ok <- validate_batch_size(batch_size),
         {:ok, records} <- store_read(state, :read, [[after_cursor: -1]]) do
      records =
        records
        |> Enum.filter(fn record ->
          Map.fetch!(record, "timestamp_ms") >= start_timestamp &&
            Router.matches?(record_type(record), path)
        end)
        |> maybe_take(batch_size)
        |> Enum.map(&record_to_public!/1)

      {:ok, records}
    end
  end

  defp replay_records(_state, _path, _start_timestamp, _opts),
    do: {:error, {:invalid_argument, :start_timestamp}}

  defp validate_batch_size(:infinity), do: :ok
  defp validate_batch_size(size) when is_integer(size) and size > 0, do: :ok
  defp validate_batch_size(_size), do: {:error, {:invalid_option, :batch_size}}

  defp maybe_take(records, :infinity), do: records
  defp maybe_take(records, count), do: Enum.take(records, count)

  defp acknowledge(state, subscription_id, record_ids) do
    with {:ok, subscriber} <- fetch_persistent_subscriber(state, subscription_id),
         {:ok, ids} <- normalize_ack_ids(record_ids),
         :ok <- validate_pending_ids(subscriber, ids) do
      subscriber = %{subscriber | pending: Map.drop(subscriber.pending, ids)}
      persist_subscriber_checkpoint(state, subscriber)
    end
  end

  defp normalize_ack_ids(id) when is_binary(id), do: {:ok, [id]}

  defp normalize_ack_ids(ids) when is_list(ids) do
    if ids != [] && Enum.all?(ids, &is_binary/1),
      do: {:ok, Enum.uniq(ids)},
      else: {:error, :invalid_ack_argument}
  end

  defp normalize_ack_ids(_ids), do: {:error, :invalid_ack_argument}

  defp validate_pending_ids(subscriber, ids) do
    if Enum.all?(ids, &Map.has_key?(subscriber.pending, &1)),
      do: :ok,
      else: {:error, :unknown_signal_id}
  end

  defp reconnect_subscriber(_state, _subscription_id, client_pid) when not is_pid(client_pid),
    do: {:error, :invalid_client_pid}

  defp reconnect_subscriber(state, subscription_id, client_pid) do
    with {:ok, subscriber} <- fetch_persistent_subscriber(state, subscription_id),
         {:ok, checkpoint} <-
           store_read(state, :get_checkpoint, [checkpoint_key(state, subscription_id)]) do
      state = demonitor_subscriber(state, subscriber)
      {monitor_ref, state} = monitor_subscriber(state, subscription_id, client_pid)

      subscriber = %{
        subscriber
        | dispatch: replace_dispatch_pid(subscriber.dispatch, client_pid),
          client_pid: client_pid,
          monitor_ref: monitor_ref,
          disconnected?: false,
          pending: %{},
          last_seen_cursor: checkpoint || 0
      }

      state = put_subscriber(state, subscriber)

      with {:ok, records} <- store_read(state, :read, [[after_cursor: checkpoint || 0]]),
           {:ok, state} <-
             records
             |> Enum.filter(&Router.matches?(record_type(&1), subscriber.path))
             |> deliver_records_to_subscriber(state, subscription_id) do
        {:ok, checkpoint || 0, state}
      else
        {:error, reason, _state} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp redrive(state, subscription_id, opts) do
    with {:ok, subscriber} <- fetch_subscriber(state, subscription_id),
         :ok <- validate_batch_size(Keyword.get(opts, :limit, :infinity)),
         {:ok, entries} <- store_read(state, :list_dlq, [subscription_id]) do
      do_redrive(state, subscriber, entries, opts)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp do_redrive(state, subscriber, entries, opts) do
    selected = maybe_take(entries, Keyword.get(opts, :limit, :infinity))

    {succeeded, failed, successful_ids, state} =
      Enum.reduce(selected, {0, 0, [], state}, &redrive_entry(&1, &2, subscriber))

    clear_on_success? = Keyword.get(opts, :clear_on_success, true)

    case maybe_delete_redriven(state, subscriber.id, successful_ids, clear_on_success?) do
      {:ok, state} -> finish_redrive(state, subscriber.id, succeeded, failed)
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp redrive_entry(entry, {succeeded, failed, ids, state}, subscriber) do
    signal = entry |> Map.fetch!("record") |> record_to_public!() |> Map.fetch!(:signal)

    case run_dispatch(state, signal, subscriber) do
      {:ok, state} -> {succeeded + 1, failed, [Map.fetch!(entry, "id") | ids], state}
      {:skip, state} -> {succeeded + 1, failed, [Map.fetch!(entry, "id") | ids], state}
      {:error, _reason, state} -> {succeeded, failed + 1, ids, state}
    end
  end

  defp finish_redrive(state, subscription_id, succeeded, failed) do
    result = %{succeeded: succeeded, failed: failed}

    Telemetry.execute(
      [:jido, :signal, :bus, :dlq, :redrive],
      result,
      %{bus_name: state.name, subscription_id: subscription_id}
    )

    {:ok, result, state}
  end

  defp maybe_delete_redriven(state, _subscription_id, _ids, false), do: {:ok, state}

  defp maybe_delete_redriven(state, subscription_id, ids, true),
    do: store_write(state, :delete_dlq, [subscription_id, ids])

  defp fetch_subscriber(state, id) do
    case Map.fetch(state.subscriptions, id) do
      {:ok, subscriber} -> {:ok, subscriber}
      :error -> {:error, :subscription_not_found}
    end
  end

  defp fetch_persistent_subscriber(state, id) do
    with {:ok, subscriber} <- fetch_subscriber(state, id) do
      if subscriber.persistent?,
        do: {:ok, subscriber},
        else: {:error, :subscription_not_persistent}
    end
  end

  defp maybe_delete_retained_subscription(state, subscriber, opts) do
    if subscriber.persistent? && Keyword.get(opts, :delete_persistence, false) do
      case store_write(state, :delete_checkpoint, [checkpoint_key(state, subscriber.id)]) do
        {:ok, state} -> store_write(state, :clear_dlq, [subscriber.id])
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, state}
    end
  end

  defp store_read(state, callback, args) do
    case safe_apply(state.store_module, callback, args ++ [state.store_state]) do
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

  defp record_to_public!(record) do
    {:ok, signal} = Signal.from_map(Map.fetch!(record, "signal"))
    {:ok, created_at, _offset} = DateTime.from_iso8601(Map.fetch!(record, "created_at"))

    %RecordedSignal{
      id: Map.fetch!(record, "id"),
      cursor: Map.fetch!(record, "cursor"),
      type: Map.fetch!(record, "type"),
      created_at: created_at,
      signal: signal
    }
  end

  defp dlq_store_entry(subscription_id, record, reason) do
    %{
      "format_version" => 1,
      "id" => ID.generate!(),
      "subscription_id" => subscription_id,
      "record" => record,
      "reason" => Error.to_map(Error.normalize(reason)),
      "metadata" => %{
        "signal_log_id" => Map.fetch!(record, "id"),
        "attempt_count" => 1
      },
      "inserted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp decode_dlq_entries(entries) do
    decoded =
      Enum.map(entries, fn entry ->
        {:ok, inserted_at, _offset} = DateTime.from_iso8601(Map.fetch!(entry, "inserted_at"))

        %{
          id: Map.fetch!(entry, "id"),
          subscription_id: Map.fetch!(entry, "subscription_id"),
          signal: entry |> Map.fetch!("record") |> record_to_public!() |> Map.fetch!(:signal),
          reason: Map.fetch!(entry, "reason"),
          metadata: Map.fetch!(entry, "metadata"),
          inserted_at: inserted_at
        }
      end)

    {:ok, decoded}
  end

  defp record_type(record), do: Map.fetch!(record, "type")

  defp checkpoint_key(state, subscription_id), do: "#{state.name}:#{subscription_id}"

  defp dispatch_pid({:pid, opts}), do: Keyword.get(opts, :target)

  defp dispatch_pid(targets) when is_list(targets) do
    Enum.find_value(targets, fn
      {:pid, opts} -> Keyword.get(opts, :target)
      _target -> nil
    end)
  end

  defp dispatch_pid(_dispatch), do: nil

  defp replace_dispatch_pid({:pid, opts}, pid), do: {:pid, Keyword.put(opts, :target, pid)}

  defp replace_dispatch_pid(targets, pid) when is_list(targets) do
    Enum.map(targets, fn
      {:pid, opts} -> {:pid, Keyword.put(opts, :target, pid)}
      target -> target
    end)
  end

  defp replace_dispatch_pid(_dispatch, pid),
    do: {:pid, target: pid, delivery_mode: :async}

  defp monitor_subscriber(state, _id, nil), do: {nil, state}

  defp monitor_subscriber(state, id, pid) when is_pid(pid) do
    monitor_ref = Process.monitor(pid)
    {monitor_ref, %{state | monitors: Map.put(state.monitors, monitor_ref, id)}}
  end

  defp demonitor_subscriber(state, %Subscriber{monitor_ref: nil}), do: state

  defp demonitor_subscriber(state, %Subscriber{monitor_ref: monitor_ref}) do
    Process.demonitor(monitor_ref, [:flush])
    %{state | monitors: Map.delete(state.monitors, monitor_ref)}
  end

  defp remove_subscriber(state, subscriber, demonitor? \\ true) do
    state = if demonitor?, do: demonitor_subscriber(state, subscriber), else: state

    %{
      state
      | subscriptions: Map.delete(state.subscriptions, subscriber.id),
        subscription_order: Enum.reject(state.subscription_order, &(&1 == subscriber.id))
    }
  end

  defp put_subscriber(state, subscriber) do
    %{state | subscriptions: Map.put(state.subscriptions, subscriber.id, subscriber)}
  end

  defp insert_subscriber(state, subscriber) do
    %{
      state
      | subscriptions: Map.put(state.subscriptions, subscriber.id, subscriber),
        subscription_order: state.subscription_order ++ [subscriber.id]
    }
  end

  defp middleware_context(state) do
    %{bus_name: state.name, timestamp: DateTime.utc_now(), metadata: %{}}
  end

  defp emit_dispatch(event, state, signal, subscriber, extra) do
    metadata =
      Map.merge(
        %{
          bus_name: state.name,
          signal_id: signal.id,
          signal_type: signal.type,
          subscription_id: subscriber.id,
          subscription_path: subscriber.path,
          signal: signal,
          subscription: subscriber
        },
        extra
      )

    Telemetry.execute(
      [:jido, :signal, :bus, event],
      %{timestamp: System.monotonic_time(:microsecond)},
      metadata
    )
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
