defmodule Jido.Signal.Bus.Subscriptions.Subscriber do
  @moduledoc false

  @enforce_keys [:id, :path, :durable?, :cursor, :created_at]
  defstruct [
    :id,
    :path,
    :target,
    :monitor_ref,
    :in_flight,
    :created_at,
    durable?: false,
    cursor: 0
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          path: String.t(),
          durable?: boolean(),
          target: pid() | nil,
          monitor_ref: reference() | nil,
          cursor: non_neg_integer(),
          in_flight: pos_integer() | nil,
          created_at: DateTime.t()
        }
end

defmodule Jido.Signal.Bus.Subscriptions do
  @moduledoc false

  alias Jido.Signal.Bus.DurableSubscription
  alias Jido.Signal.Bus.Subscriptions.Subscriber
  alias Jido.Signal.ID
  alias Jido.Signal.Router
  alias Jido.Signal.Telemetry

  @subscription_options [:target, :subscription_id, :durable, :start_from]

  @doc false
  @spec subscribe(map(), Router.path(), keyword()) ::
          {:ok, String.t(), map()} | {:error, term(), map()}
  def subscribe(state, path, opts) do
    with :ok <- validate_options(opts),
         :ok <- validate_path(path),
         {:ok, target} <- validate_target(Keyword.get(opts, :target)),
         {:ok, kind, id} <- subscription_identity(opts) do
      case kind do
        :ephemeral -> add_ephemeral(state, id, path, target)
        :durable -> DurableSubscription.attach(state, id, path, target, opts)
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  @doc false
  @spec unsubscribe(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def unsubscribe(state, subscription_id, []) do
    case Map.get(state.subscriptions, subscription_id) do
      nil -> {:error, :subscription_not_found}
      %Subscriber{durable?: true} = subscriber -> DurableSubscription.detach(state, subscriber)
      %Subscriber{} = subscriber -> {:ok, remove_subscriber(state, subscriber)}
    end
  end

  def unsubscribe(_state, _subscription_id, _opts), do: {:error, :invalid_options}

  @doc false
  @spec delete(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete(state, subscription_id) do
    case Map.get(state.subscriptions, subscription_id) do
      nil -> {:error, :subscription_not_found}
      %Subscriber{durable?: true} = subscriber -> DurableSubscription.delete(state, subscriber)
      %Subscriber{} = subscriber -> {:ok, remove_subscriber(state, subscriber)}
    end
  end

  @doc false
  @spec acknowledge(map(), String.t(), term(), pid()) ::
          {:ok, map()} | {:error, term(), map()}
  def acknowledge(state, durable_id, cursor, caller) do
    DurableSubscription.acknowledge(state, durable_id, cursor, caller)
  end

  @doc false
  @spec target_down(map(), reference()) :: map()
  def target_down(state, monitor_ref) do
    case Map.pop(state.monitors, monitor_ref) do
      {nil, _monitors} ->
        state

      {subscription_id, monitors} ->
        state = %{state | monitors: monitors}

        case Map.get(state.subscriptions, subscription_id) do
          nil ->
            state

          %Subscriber{durable?: true} = subscriber ->
            DurableSubscription.target_down(state, subscriber)

          %Subscriber{} = subscriber ->
            remove_subscriber(state, subscriber, false)
        end
    end
  end

  @doc false
  @spec deliver_published(map(), Jido.Signal.t()) :: map()
  def deliver_published(%{subscriptions: subscriptions} = state, _signal)
      when map_size(subscriptions) == 0,
      do: state

  def deliver_published(state, signal) do
    case Router.route(state.router, signal) do
      {:ok, subscription_ids} ->
        Enum.reduce(subscription_ids, state, &deliver_to_subscription(&1, signal, &2))

      {:error, _no_match} ->
        state
    end
  end

  @doc false
  @spec load(term()) :: {:ok, map(), [String.t()], Router.t()} | {:error, term()}
  defdelegate load(definitions), to: DurableSubscription

  @doc false
  @spec validate_loaded_cursors(map(), non_neg_integer()) :: :ok | {:error, atom()}
  defdelegate validate_loaded_cursors(subscriptions, latest_cursor), to: DurableSubscription

  defp validate_options(opts) do
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
    cond do
      target == self() -> {:error, :target_is_bus}
      Process.alive?(target) -> {:ok, target}
      true -> {:error, :target_not_alive}
    end
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
      monitor_ref = Process.monitor(target)
      state = %{state | monitors: Map.put(state.monitors, monitor_ref, id)}

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

  defp deliver_to_subscription(subscription_id, signal, state) do
    case Map.fetch!(state.subscriptions, subscription_id) do
      %Subscriber{durable?: true} = subscriber ->
        DurableSubscription.deliver(state, subscriber, signal)

      %Subscriber{target: target} = subscriber ->
        send(target, {:signal, signal})
        emit_delivery(state, subscriber, signal)
        state
    end
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

  defp demonitor_target(state, %Subscriber{monitor_ref: nil}), do: state

  defp demonitor_target(state, %Subscriber{monitor_ref: monitor_ref}) do
    Process.demonitor(monitor_ref, [:flush])
    %{state | monitors: Map.delete(state.monitors, monitor_ref)}
  end

  defp emit_subscription(event, state, subscriber) do
    Telemetry.execute(
      [:jido, :signal, :bus, :subscription, event],
      %{system_time: System.system_time()},
      %{
        bus_name: state.name,
        subscription_id: subscriber.id,
        subscription_path: subscriber.path,
        durable: false
      }
    )
  end

  defp emit_delivery(state, subscriber, signal) do
    Telemetry.execute(
      [:jido, :signal, :bus, :deliver],
      %{system_time: System.system_time()},
      %{
        bus_name: state.name,
        subscription_id: subscriber.id,
        subscription_path: subscriber.path,
        durable: false,
        cursor: nil,
        signal_id: signal.id,
        signal_type: signal.type
      },
      signal
    )
  end
end
