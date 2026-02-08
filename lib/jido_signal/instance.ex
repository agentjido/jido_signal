defmodule Jido.Signal.Instance do
  @moduledoc """
  Manages instance-scoped signal infrastructure.

  Provides a child_spec for starting instance-scoped supervisors that mirror
  the global signal infrastructure but are isolated to a specific instance.

  ## Usage

  Add to your application's supervision tree:

      children = [
        # Global signal infrastructure starts automatically via application.ex

        # Instance-scoped infrastructure
        {Jido.Signal.Instance, name: MyApp.Jido}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  Then use the `jido:` option to route operations through your instance:

      {:ok, bus} = Jido.Signal.Bus.start_link(
        name: :my_bus,
        jido: MyApp.Jido
      )

  ## Child Processes

  Each instance starts:
  - Registry (for managing signal subscriptions)
  - TaskSupervisor (for async operations)
  - Extension Registry (for signal extensions)

  """

  alias Jido.Signal.Names

  @type option ::
          {:name, atom()}
          | {:shutdown, timeout()}

  @doc """
  Returns a child specification for starting an instance supervisor.

  ## Options

    * `:name` - The instance name (required). This will be used as the prefix
      for all child process names.
    * `:shutdown` - Shutdown timeout (default: 5000)

  ## Examples

      # In your supervision tree
      {Jido.Signal.Instance, name: MyApp.Jido}

      # With custom shutdown
      {Jido.Signal.Instance, name: MyApp.Jido, shutdown: 10_000}

  """
  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)
    shutdown = Keyword.get(opts, :shutdown, 5000)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: shutdown
    }
  end

  @doc """
  Starts an instance supervisor with the given options.

  ## Options

    * `:name` - The instance name (required)

  ## Returns

    * `{:ok, pid}` - Instance supervisor started successfully
    * `{:error, reason}` - Failed to start

  """
  @spec start_link([option()]) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    instance_opts = [jido: name, allow_unregistered?: true]

    :ok = Names.register_instance(name)

    children = [
      {Registry, keys: :unique, name: Names.registry(instance_opts)},
      Jido.Signal.Ext.Registry.child_spec(name: Names.ext_registry(instance_opts)),
      {Task.Supervisor, name: Names.task_supervisor(instance_opts)},
      {Jido.Signal.Bus.RuntimeSupervisor, name: Names.bus_runtime_supervisor(instance_opts)},
      {Jido.Signal.Bus.SnapshotStore, name: Names.snapshot_store(instance_opts)},
      {Jido.Signal.Router.Cache.ManagedMonitor, name: Names.router_cache_monitor(instance_opts)}
    ]

    supervisor_name = Names.supervisor(instance_opts)

    case Supervisor.start_link(children, strategy: :rest_for_one, name: supervisor_name) do
      {:ok, _pid} = ok ->
        ok

      {:error, {:already_started, _pid}} = error ->
        error

      {:error, reason} ->
        :ok = Names.unregister_instance(name)
        {:error, reason}
    end
  end

  @doc """
  Checks if an instance is running.

  This is an advisory liveness check. The process may terminate immediately after this function
  returns `true`.

  ## Examples

      iex> Jido.Signal.Instance.running?(MyApp.Jido)
      true

  """
  @spec running?(atom()) :: boolean()
  def running?(instance) when is_atom(instance) do
    instance_opts = [jido: instance, allow_unregistered?: true]
    supervisor_name = Names.supervisor(instance_opts)

    case Process.whereis(supervisor_name) do
      pid when is_pid(pid) ->
        :ok = Names.register_instance(instance)
        is_pid(pid)

      _ ->
        false
    end
  end

  @doc """
  Stops an instance supervisor.

  ## Examples

      :ok = Jido.Signal.Instance.stop(MyApp.Jido)

  """
  @spec stop(atom(), timeout()) :: :ok
  def stop(instance, timeout \\ 5000) when is_atom(instance) do
    instance_opts = [jido: instance, allow_unregistered?: true]
    supervisor_name = Names.supervisor(instance_opts)

    result =
      case Process.whereis(supervisor_name) do
        nil ->
          :ok

        pid when is_pid(pid) ->
          try do
            Supervisor.stop(pid, :normal, timeout)
          catch
            :exit, {:noproc, _} -> :ok
            :exit, _ -> :ok
          end
      end

    :ok = Names.unregister_instance(instance)
    result
  end
end
