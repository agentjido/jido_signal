defmodule Jido.Signal.Bus.Subscriber do
  @moduledoc """
  Defines the subscriber model and subscription management for the signal bus.

  This module contains the subscriber type definition and functions for creating,
  managing, and dispatching signals to subscribers. It supports both regular and
  persistent subscriptions, handling subscription lifetime and signal delivery.
  """

  alias Jido.Signal.Bus.PersistentRef
  alias Jido.Signal.Bus.PersistentSubscription
  alias Jido.Signal.Bus.State, as: BusState
  alias Jido.Signal.Bus.Subscriber
  alias Jido.Signal.Context
  alias Jido.Signal.Error
  alias Jido.Signal.Router

  @dispatch_opts_schema Zoi.list(Zoi.tuple({Zoi.atom(), Zoi.any()}))
  @dispatch_config_schema Zoi.tuple({Zoi.atom(), @dispatch_opts_schema})
  @dispatch_schema Zoi.union([@dispatch_config_schema, Zoi.list(@dispatch_config_schema)])

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              path: Zoi.string(),
              dispatch: @dispatch_schema,
              persistent?: Zoi.default(Zoi.boolean(), false) |> Zoi.optional(),
              persistence_pid: Zoi.pid() |> Zoi.nullable() |> Zoi.optional(),
              persistence_ref: Zoi.any() |> Zoi.nullable() |> Zoi.optional(),
              disconnected?: Zoi.default(Zoi.boolean(), false) |> Zoi.optional(),
              created_at: Zoi.default(Zoi.datetime(), DateTime.utc_now())
            }
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for Subscriber"
  def schema, do: @schema

  @spec subscribe(BusState.t(), String.t(), String.t(), keyword()) ::
          {:ok, BusState.t()} | {:error, Exception.t()}
  def subscribe(%BusState{} = state, subscription_id, path, opts) do
    if BusState.has_subscription?(state, subscription_id) do
      {:error,
       Error.validation_error(
         "Subscription already exists",
         %{field: :subscription_id, value: subscription_id}
       )}
    else
      do_subscribe(state, subscription_id, path, opts)
    end
  end

  defp do_subscribe(state, subscription_id, path, opts) do
    persistent? = Keyword.get(opts, :persistent?, Keyword.get(opts, :persistent, false))
    dispatch = Keyword.get(opts, :dispatch)

    if is_nil(dispatch) do
      {:error,
       Error.validation_error("dispatch is required", %{field: :dispatch, value: dispatch})}
    else
      do_subscribe_with_dispatch(state, subscription_id, path, opts, persistent?, dispatch)
    end
  end

  defp do_subscribe_with_dispatch(state, subscription_id, path, opts, persistent?, dispatch) do
    subscription = %Subscriber{
      id: subscription_id,
      path: path,
      dispatch: dispatch,
      persistent?: persistent?,
      persistence_pid: nil,
      persistence_ref: nil,
      created_at: DateTime.utc_now()
    }

    if persistent? do
      create_persistent_subscription(state, subscription_id, subscription, opts)
    else
      create_regular_subscription(state, subscription_id, subscription)
    end
  end

  defp create_persistent_subscription(state, subscription_id, subscription, opts) do
    if is_nil(state.child_supervisor) do
      {:error,
       Error.execution_error(
         "Failed to start persistent subscription",
         %{action: "start_persistent_subscription", reason: :missing_child_supervisor}
       )}
    else
      do_create_persistent_subscription(state, subscription_id, subscription, opts)
    end
  end

  defp do_create_persistent_subscription(state, subscription_id, subscription, opts) do
    client_pid = extract_client_pid(subscription.dispatch)

    persistent_sub_opts =
      build_persistent_opts(state, subscription_id, subscription, client_pid, opts)

    case start_persistent_child(state, persistent_sub_opts) do
      {:ok, pid} ->
        finalize_persistent_subscription(state, subscription_id, subscription, pid)

      {:error, reason} ->
        {:error,
         Error.execution_error(
           "Failed to start persistent subscription",
           %{action: "start_persistent_subscription", reason: reason}
         )}
    end
  end

  defp build_persistent_opts(state, subscription_id, subscription, client_pid, opts) do
    [
      id: subscription_id,
      bus_pid: self(),
      bus_name: state.name,
      bus_subscription: subscription,
      start_from: opts[:start_from] || :origin,
      max_in_flight: opts[:max_in_flight] || 1000,
      max_pending: opts[:max_pending] || 10_000,
      max_attempts: opts[:max_attempts] || 5,
      retry_interval: opts[:retry_interval] || 100,
      client_pid: client_pid,
      jido: state.jido,
      journal_adapter: state.journal_adapter,
      journal_pid: state.journal_pid
    ]
  end

  defp start_persistent_child(state, persistent_sub_opts) do
    DynamicSupervisor.start_child(
      state.child_supervisor,
      {PersistentSubscription, persistent_sub_opts}
    )
  end

  defp finalize_persistent_subscription(state, subscription_id, subscription, pid) do
    persistence_ref =
      PersistentRef.new(state.name, subscription_id, Context.jido_opts(state), pid)

    subscription = %{subscription | persistence_pid: pid, persistence_ref: persistence_ref}

    case BusState.add_subscription(state, subscription_id, subscription) do
      {:ok, new_state} ->
        {:ok, new_state}

      {:error, reason} ->
        {:error,
         Error.execution_error(
           "Failed to add subscription",
           %{action: "add_subscription", reason: reason}
         )}
    end
  end

  defp create_regular_subscription(state, subscription_id, subscription) do
    new_state = %{
      state
      | subscriptions: Map.put(state.subscriptions, subscription_id, subscription)
    }

    route = %Router.Route{
      path: subscription.path,
      target: subscription.dispatch,
      priority: 0,
      match: nil
    }

    case BusState.add_route(new_state, route) do
      {:ok, final_state} ->
        {:ok, final_state}

      {:error, reason} ->
        {:error,
         Error.execution_error(
           "Failed to add subscription route",
           %{action: "add_route", reason: reason}
         )}
    end
  end

  @doc """
  Unsubscribes from the bus by removing the subscription and cleaning up resources.

  For persistent subscriptions, this also terminates the associated process.

  ## Parameters

  - `state`: The current bus state
  - `subscription_id`: The unique identifier of the subscription to remove
  - `opts`: Additional options
    - `:delete_persistence` - whether to remove checkpoint + DLQ persistence data (default: false)

  ## Returns

  - `{:ok, new_state}` if successful
  - `{:error, Exception.t()}` if the subscription doesn't exist or removal fails
  """
  @spec unsubscribe(BusState.t(), String.t(), keyword()) ::
          {:ok, BusState.t()} | {:error, Exception.t()}
  def unsubscribe(%BusState{} = state, subscription_id, opts \\ []) do
    delete_persistence = Keyword.get(opts, :delete_persistence, false)

    # Get the subscription before removing it
    subscription = BusState.get_subscription(state, subscription_id)

    case BusState.remove_subscription(state, subscription_id, opts) do
      {:ok, new_state} ->
        cleanup_persistent_subscription(state, subscription, subscription_id, delete_persistence)
        {:ok, new_state}

      {:error, :subscription_not_found} ->
        {:error,
         Error.validation_error(
           "Subscription does not exist",
           %{field: :subscription_id, value: subscription_id}
         )}
    end
  end

  defp cleanup_persistent_subscription(_state, nil, _subscription_id, _delete_persistence),
    do: :ok

  defp cleanup_persistent_subscription(_state, %{persistent?: false}, _sub_id, _del), do: :ok

  defp cleanup_persistent_subscription(state, subscription, subscription_id, delete_persistence) do
    target =
      subscription
      |> PersistentRef.from_subscription(state.name, Context.jido_opts(state))
      |> PersistentRef.target()

    if target, do: stop_persistent_subscription(state.child_supervisor, target)
    if delete_persistence, do: delete_persistent_data(state, subscription_id)
    :ok
  end

  # Helper function to extract client PID from dispatch configuration
  @spec extract_client_pid(term()) :: pid() | nil
  defp extract_client_pid({:pid, opts}) when is_list(opts) do
    Keyword.get(opts, :target)
  end

  defp extract_client_pid(_) do
    nil
  end

  defp stop_persistent_subscription(nil, pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  defp stop_persistent_subscription(nil, target) do
    GenServer.stop(target, :normal)
  catch
    :exit, _ -> :ok
  end

  defp stop_persistent_subscription(child_supervisor, pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(child_supervisor, pid)
  catch
    :exit, _ -> :ok
  end

  defp stop_persistent_subscription(_child_supervisor, target) do
    GenServer.stop(target, :normal)
  catch
    :exit, _ -> :ok
  end

  defp delete_persistent_data(%{journal_adapter: nil}, _subscription_id), do: :ok

  defp delete_persistent_data(state, subscription_id) do
    checkpoint_key = "#{state.name}:#{subscription_id}"

    _ =
      safe_persistence_cleanup(
        state.journal_adapter,
        :delete_checkpoint,
        checkpoint_key,
        state.journal_pid
      )

    _ =
      safe_persistence_cleanup(
        state.journal_adapter,
        :clear_dlq,
        subscription_id,
        state.journal_pid
      )

    :ok
  end

  defp safe_persistence_cleanup(adapter, function, id, journal_pid) do
    if function_exported?(adapter, function, 2) do
      try do
        apply(adapter, function, [id, journal_pid])
      catch
        :exit, _ -> :ok
      end
    else
      :ok
    end
  end
end
