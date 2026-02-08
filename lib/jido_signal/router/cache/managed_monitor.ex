defmodule Jido.Signal.Router.Cache.ManagedMonitor do
  @moduledoc false

  use GenServer

  alias Jido.Signal.Router.Cache

  @type cache_id :: atom() | {atom(), term()}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @doc false
  @spec register(cache_id(), pid()) :: :ok
  def register(cache_id, owner_pid) when is_pid(owner_pid) do
    GenServer.call(__MODULE__, {:register, cache_id, owner_pid})
  catch
    :exit, _ -> :ok
  end

  @doc false
  @spec unregister(cache_id()) :: :ok
  def unregister(cache_id) do
    GenServer.cast(__MODULE__, {:unregister, cache_id})
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl GenServer
  def init(:ok) do
    {:ok, %{by_cache: %{}, by_ref: %{}}}
  end

  @impl GenServer
  def handle_call({:register, cache_id, owner_pid}, _from, state) do
    state = unregister_cache(cache_id, state)
    ref = Process.monitor(owner_pid)

    next_state = %{
      state
      | by_cache: Map.put(state.by_cache, cache_id, {owner_pid, ref}),
        by_ref: Map.put(state.by_ref, ref, cache_id)
    }

    {:reply, :ok, next_state}
  end

  @impl GenServer
  def handle_cast({:unregister, cache_id}, state) do
    {:noreply, unregister_cache(cache_id, state)}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _owner_pid, _reason}, state) do
    case Map.pop(state.by_ref, ref) do
      {nil, _} ->
        {:noreply, state}

      {cache_id, next_by_ref} ->
        next_state = %{
          state
          | by_ref: next_by_ref,
            by_cache: Map.delete(state.by_cache, cache_id)
        }

        Cache.delete_managed(cache_id)
        {:noreply, next_state}
    end
  end

  defp unregister_cache(cache_id, state) do
    case Map.pop(state.by_cache, cache_id) do
      {nil, _} ->
        state

      {{_owner_pid, ref}, next_by_cache} ->
        Process.demonitor(ref, [:flush])
        %{state | by_cache: next_by_cache, by_ref: Map.delete(state.by_ref, ref)}
    end
  end
end
