defmodule Jido.Signal.Bus.PartitionSupervisor do
  @moduledoc """
  Supervises partition workers for a bus.

  Each bus with partition_count > 1 will have a PartitionSupervisor that manages
  the partition workers. This enables horizontal scaling of signal dispatch.
  """
  use Supervisor

  alias Jido.Signal.Bus.Partition
  alias Jido.Signal.Names

  @doc """
  Starts the partition supervisor.

  ## Options

    * `:bus_name` - The name of the parent bus (required)
    * `:partition_count` - Number of partitions to create (default: 1)
    * `:middleware` - Middleware configurations (optional)
    * `:middleware_timeout_ms` - Timeout for middleware execution (default: 100)
    * `:journal_adapter` - Journal adapter module (optional)
    * `:journal_pid` - Journal adapter PID (optional)
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    bus_name = Keyword.fetch!(opts, :bus_name)
    do_start_link(opts, bus_name, 3)
  end

  defp do_start_link(opts, bus_name, attempts) do
    case Supervisor.start_link(__MODULE__, opts, name: via_tuple(bus_name, opts)) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} when is_pid(pid) ->
        resolve_existing_supervisor(
          pid,
          fn -> do_start_link(opts, bus_name, attempts - 1) end,
          attempts
        )

      other ->
        other
    end
  end

  defp resolve_existing_supervisor(pid, retry_fun, attempts) do
    if Process.alive?(pid) do
      {:ok, pid}
    else
      retry_or_conflict(retry_fun, attempts)
    end
  end

  defp retry_or_conflict(retry_fun, attempts) when attempts > 0 do
    receive do
    after
      10 -> retry_fun.()
    end
  end

  defp retry_or_conflict(_retry_fun, _attempts), do: {:error, :name_conflict}

  @doc """
  Returns a via tuple for looking up a partition supervisor by bus name.
  """
  @spec via_tuple(atom(), keyword()) :: {:via, Registry, {module(), tuple()}}
  def via_tuple(bus_name, opts \\ []) do
    {:via, Registry, {Names.registry(opts), {:partition_supervisor, bus_name}}}
  end

  @impl Supervisor
  def init(opts) do
    partition_count = Keyword.get(opts, :partition_count, 1)
    bus_name = Keyword.fetch!(opts, :bus_name)
    middleware = Keyword.get(opts, :middleware, [])
    middleware_timeout_ms = Keyword.get(opts, :middleware_timeout_ms, 100)
    journal_adapter = Keyword.get(opts, :journal_adapter)
    journal_pid = Keyword.get(opts, :journal_pid)
    jido = Keyword.get(opts, :jido)
    rate_limit_per_sec = Keyword.get(opts, :rate_limit_per_sec, 10_000)
    burst_size = Keyword.get(opts, :burst_size, 1_000)

    children =
      for i <- 0..(partition_count - 1) do
        Supervisor.child_spec(
          {Partition,
           [
             partition_id: i,
             bus_name: bus_name,
             jido: jido,
             middleware: middleware,
             middleware_timeout_ms: middleware_timeout_ms,
             journal_adapter: journal_adapter,
             journal_pid: journal_pid,
             rate_limit_per_sec: rate_limit_per_sec,
             burst_size: burst_size
           ]},
          id: {Partition, i}
        )
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
