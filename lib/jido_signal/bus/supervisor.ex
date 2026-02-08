defmodule Jido.Signal.Bus.Supervisor do
  @moduledoc """
  Per-bus supervision tree.

  Each bus runs inside its own subtree with explicit restart boundaries:
  1. persistent subscription dynamic supervisor
  2. optional partition supervisor
  3. bus worker

  Strategy is `:rest_for_one` so failures in upstream runtime infrastructure restart
  dependent children in deterministic order while isolated bus failures only restart
  the bus worker.
  """

  use Supervisor

  alias Jido.Signal.Bus
  alias Jido.Signal.Bus.PartitionSupervisor
  alias Jido.Signal.Names

  @type whereis_result :: {:ok, pid()} | {:error, :not_found}

  @doc """
  Starts the per-bus supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    bus_name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: via_tuple(bus_name, opts))
  end

  @doc """
  Returns the supervisor registry tuple for the bus.
  """
  @spec via_tuple(atom(), keyword()) :: {:via, Registry, {module(), tuple()}}
  def via_tuple(bus_name, opts \\ []) do
    {:via, Registry, {Names.registry(opts), {:bus_supervisor, bus_name}}}
  end

  @doc """
  Returns the persistent subscription dynamic supervisor registry tuple for the bus.
  """
  @spec persistent_supervisor_via_tuple(atom(), keyword()) ::
          {:via, Registry, {module(), tuple()}}
  def persistent_supervisor_via_tuple(bus_name, opts \\ []) do
    {:via, Registry, {Names.registry(opts), {:persistent_subscription_supervisor, bus_name}}}
  end

  @doc """
  Looks up a running per-bus supervisor.
  """
  @spec whereis(atom(), keyword()) :: whereis_result()
  def whereis(bus_name, opts \\ []) do
    case GenServer.whereis(via_tuple(bus_name, opts)) do
      nil -> {:error, :not_found}
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  @impl Supervisor
  def init(opts) do
    bus_name = Keyword.fetch!(opts, :name)
    partition_count = Keyword.get(opts, :partition_count, 1)
    persistent_supervisor_name = persistent_supervisor_via_tuple(bus_name, opts)

    bus_opts =
      opts
      |> Keyword.put(:child_supervisor_name, persistent_supervisor_name)
      |> Keyword.put(:bus_supervisor, self())
      |> maybe_put_partition_supervisor_name(bus_name, partition_count)

    children =
      [persistent_supervisor_child(bus_name, persistent_supervisor_name)] ++
        partition_supervisor_child(bus_name, opts, partition_count) ++
        [bus_child(bus_name, bus_opts)]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp persistent_supervisor_child(bus_name, persistent_supervisor_name) do
    %{
      id: {:persistent_subscription_supervisor, bus_name},
      start:
        {DynamicSupervisor, :start_link,
         [[strategy: :one_for_one, name: persistent_supervisor_name]]},
      type: :supervisor,
      restart: :permanent,
      shutdown: 5000
    }
  end

  defp partition_supervisor_child(_bus_name, _opts, partition_count) when partition_count <= 1,
    do: []

  defp partition_supervisor_child(bus_name, opts, partition_count) do
    partition_opts = [
      partition_count: partition_count,
      bus_name: bus_name,
      jido: Keyword.get(opts, :jido),
      middleware: [],
      middleware_timeout_ms: Keyword.get(opts, :middleware_timeout_ms, 100),
      journal_adapter: Keyword.get(opts, :journal_adapter),
      journal_pid: Keyword.get(opts, :journal_pid),
      rate_limit_per_sec: Keyword.get(opts, :partition_rate_limit_per_sec, 10_000),
      burst_size: Keyword.get(opts, :partition_burst_size, 1_000)
    ]

    [
      %{
        id: {PartitionSupervisor, bus_name},
        start: {PartitionSupervisor, :start_link, [partition_opts]},
        type: :supervisor,
        restart: :permanent,
        shutdown: 5000
      }
    ]
  end

  defp bus_child(bus_name, bus_opts) do
    %{
      id: {Bus, bus_name},
      start: {Bus, :start_bus_link, [bus_name, bus_opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  defp maybe_put_partition_supervisor_name(opts, _bus_name, partition_count)
       when partition_count <= 1 do
    opts
  end

  defp maybe_put_partition_supervisor_name(opts, bus_name, _partition_count) do
    Keyword.put(opts, :partition_supervisor_name, PartitionSupervisor.via_tuple(bus_name, opts))
  end
end
