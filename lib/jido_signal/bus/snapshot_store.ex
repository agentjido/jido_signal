defmodule Jido.Signal.Bus.SnapshotStore do
  @moduledoc false

  use GenServer

  alias Jido.Signal.Context
  alias Jido.Signal.Names

  @type key :: {atom() | nil, atom() | binary(), String.t()}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @doc false
  @spec put(atom() | binary(), atom() | nil, String.t(), term()) :: :ok | {:error, term()}
  def put(bus_name, jido, snapshot_id, snapshot_data) do
    call_store(jido, {:put, snapshot_key(jido, bus_name, snapshot_id), snapshot_data})
  end

  @doc false
  @spec get(atom() | binary(), atom() | nil, String.t()) :: {:ok, term()} | :error
  def get(bus_name, jido, snapshot_id) do
    call_store(jido, {:get, snapshot_key(jido, bus_name, snapshot_id)})
  end

  @doc false
  @spec delete(atom() | binary(), atom() | nil, String.t()) :: :ok
  def delete(bus_name, jido, snapshot_id) do
    case call_store(jido, {:delete, snapshot_key(jido, bus_name, snapshot_id)}) do
      :ok -> :ok
      _ -> :ok
    end
  end

  @doc false
  @spec delete_bus(atom() | binary(), atom() | nil) :: :ok
  def delete_bus(bus_name, jido) do
    case call_store(jido, {:delete_bus, jido, bus_name}) do
      :ok -> :ok
      _ -> :ok
    end
  end

  @impl GenServer
  def init(:ok) do
    table =
      :ets.new(__MODULE__, [
        :set,
        :protected,
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])

    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call({:put, key, snapshot_data}, _from, state) do
    true = :ets.insert(state.table, {key, snapshot_data})
    {:reply, :ok, state}
  end

  def handle_call({:get, key}, _from, state) do
    reply =
      case :ets.lookup(state.table, key) do
        [{^key, snapshot_data}] -> {:ok, snapshot_data}
        [] -> :error
      end

    {:reply, reply, state}
  end

  def handle_call({:delete, key}, _from, state) do
    :ets.delete(state.table, key)
    {:reply, :ok, state}
  end

  def handle_call({:delete_bus, jido, bus_name}, _from, state) do
    state.table
    |> :ets.match_object({{jido, bus_name, :_}, :_})
    |> Enum.each(fn {{^jido, ^bus_name, snapshot_id}, _snapshot_data} ->
      :ets.delete(state.table, {jido, bus_name, snapshot_id})
    end)

    {:reply, :ok, state}
  end

  defp call_store(jido, message) do
    GenServer.call(store_name(jido), message, 5_000)
  catch
    :exit, _ -> {:error, :snapshot_store_unavailable}
  end

  defp store_name(nil), do: Names.snapshot_store([])

  defp store_name(jido) when is_atom(jido),
    do: Names.snapshot_store(Context.jido_opts(%{jido: jido}))

  defp snapshot_key(jido, bus_name, snapshot_id), do: {jido, bus_name, snapshot_id}
end
