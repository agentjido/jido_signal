defmodule Jido.Signal.Names do
  @moduledoc """
  Resolves process names based on optional `jido:` instance scoping.

  When `jido:` option is present, routes all operations through instance-scoped
  supervisors. When absent, uses global defaults for zero-config operation.

  ## Instance Isolation

  The `jido:` option enables complete isolation between instances:
  - Each instance has its own Registry, TaskSupervisor, and Bus processes
  - No cross-instance signal leakage
  - Easy to test isolation guarantees

  ## Atom Growth Boundary

  Scoped names are derived with `Module.concat/1`, which creates atoms for each distinct
  `{instance, component}` pair. This is acceptable for bounded, long-lived instance sets
  (for example: a small number of OTP application instances), but should not be used with
  unbounded user input as instance identifiers.

  ## Examples

      # Global (default) - uses Jido.Signal.Registry
      Names.registry([])
      #=> Jido.Signal.Registry

      # Instance-scoped - uses MyApp.Jido.Signal.Registry
      Names.registry(jido: MyApp.Jido)
      #=> MyApp.Jido.Signal.Registry

  """

  @type opts :: keyword()
  @instance_registry_key {__MODULE__, :registered_instances}
  @instance_registry_lock {__MODULE__, :instance_registry_lock}
  @instance_registry_lock_retries 3

  @doc """
  Registers an instance as approved for scoped name resolution.
  """
  @spec register_instance(atom()) :: :ok
  def register_instance(instance) when is_atom(instance) do
    with_instance_registry_lock(fn instances ->
      MapSet.put(instances, instance)
    end)
  end

  @doc """
  Removes an instance from scoped-name approval.
  """
  @spec unregister_instance(atom()) :: :ok
  def unregister_instance(instance) when is_atom(instance) do
    with_instance_registry_lock(fn instances ->
      MapSet.delete(instances, instance)
    end)
  end

  @doc """
  Returns true when an instance has been approved via `register_instance/1`.
  """
  @spec registered_instance?(atom()) :: boolean()
  def registered_instance?(instance) when is_atom(instance) do
    registered_instances()
    |> normalize_instances()
    |> MapSet.member?(instance)
  end

  @doc """
  Returns the Registry name for the given instance scope.

  ## Examples

      iex> Jido.Signal.Names.registry([])
      Jido.Signal.Registry

      iex> Jido.Signal.Names.registry(jido: MyApp.Jido)
      MyApp.Jido.Signal.Registry

  """
  @spec registry(opts()) :: atom()
  def registry(opts) do
    scoped(opts, Jido.Signal.Registry)
  end

  @doc """
  Returns the TaskSupervisor name for the given instance scope.

  ## Examples

      iex> Jido.Signal.Names.task_supervisor([])
      Jido.Signal.TaskSupervisor

      iex> Jido.Signal.Names.task_supervisor(jido: MyApp.Jido)
      MyApp.Jido.Signal.TaskSupervisor

  """
  @spec task_supervisor(opts()) :: atom()
  def task_supervisor(opts) do
    scoped(opts, Jido.Signal.TaskSupervisor)
  end

  @doc """
  Returns the Supervisor name for the given instance scope.

  ## Examples

      iex> Jido.Signal.Names.supervisor([])
      Jido.Signal.Supervisor

      iex> Jido.Signal.Names.supervisor(jido: MyApp.Jido)
      MyApp.Jido.Signal.Supervisor

  """
  @spec supervisor(opts()) :: atom()
  def supervisor(opts) do
    scoped(opts, Jido.Signal.Supervisor)
  end

  @doc """
  Returns the Extension Registry name for the given instance scope.

  ## Examples

      iex> Jido.Signal.Names.ext_registry([])
      Jido.Signal.Ext.Registry

      iex> Jido.Signal.Names.ext_registry(jido: MyApp.Jido)
      MyApp.Jido.Signal.Ext.Registry

  """
  @spec ext_registry(opts()) :: atom()
  def ext_registry(opts) do
    scoped(opts, Jido.Signal.Ext.Registry)
  end

  @doc """
  Returns the Bus runtime supervisor name for the given instance scope.

  ## Examples

      iex> Jido.Signal.Names.bus_runtime_supervisor([])
      Jido.Signal.Bus.RuntimeSupervisor

      iex> Jido.Signal.Names.bus_runtime_supervisor(jido: MyApp.Jido)
      MyApp.Jido.Signal.Bus.RuntimeSupervisor

  """
  @spec bus_runtime_supervisor(opts()) :: atom()
  def bus_runtime_supervisor(opts) do
    scoped(opts, Jido.Signal.Bus.RuntimeSupervisor)
  end

  @doc """
  Returns the SnapshotStore name for the given instance scope.

  ## Examples

      iex> Jido.Signal.Names.snapshot_store([])
      Jido.Signal.Bus.SnapshotStore

      iex> Jido.Signal.Names.snapshot_store(jido: MyApp.Jido)
      MyApp.Jido.Signal.Bus.SnapshotStore

  """
  @spec snapshot_store(opts()) :: atom()
  def snapshot_store(opts) do
    scoped(opts, Jido.Signal.Bus.SnapshotStore)
  end

  @doc """
  Returns the Router cache managed monitor name for the given instance scope.
  """
  @spec router_cache_monitor(opts()) :: atom()
  def router_cache_monitor(opts) do
    scoped(opts, Jido.Signal.Router.Cache.ManagedMonitor)
  end

  @doc """
  Resolves a module name based on instance scope.

  When `jido:` option is nil or not present, returns the default module.
  When `jido:` option is present, concatenates the instance with
  the default module's relative path under `Jido.Signal`.

  ## Examples

      iex> Jido.Signal.Names.scoped([], Jido.Signal.Registry)
      Jido.Signal.Registry

      iex> Jido.Signal.Names.scoped([jido: MyApp.Jido], Jido.Signal.Registry)
      MyApp.Jido.Signal.Registry

  """
  @spec scoped(opts(), module()) :: atom()
  def scoped(opts, default) when is_list(opts) and is_atom(default) do
    case Keyword.get(opts, :jido) do
      nil ->
        default

      instance when is_atom(instance) ->
        if instance_allowed?(opts, instance) do
          default
          |> scoped_parts()
          |> then(&Module.concat([instance | &1]))
        else
          raise ArgumentError,
                "Unregistered jido instance #{inspect(instance)}. Start it via Jido.Signal.Instance.start_link/1 before using jido-scoped APIs."
        end
    end
  end

  @doc """
  Extracts the jido instance from options, returning nil if not present.
  """
  @spec instance(opts()) :: atom() | nil
  def instance(opts) when is_list(opts) do
    Keyword.get(opts, :jido)
  end

  defp instance_allowed?(opts, instance) do
    Keyword.get(opts, :allow_unregistered?, false) or
      registered_instance?(instance) or
      running_instance_supervisor?(instance)
  end

  defp running_instance_supervisor?(instance) when is_atom(instance) do
    supervisor_name =
      scoped([jido: instance, allow_unregistered?: true], Jido.Signal.Supervisor)

    case Process.whereis(supervisor_name) do
      pid when is_pid(pid) ->
        # Self-heal transient registration drift when runtime is demonstrably alive.
        :ok = register_instance(instance)
        is_pid(pid)

      _ ->
        false
    end
  end

  defp scoped_parts(default) do
    case Module.split(default) do
      ["Jido" | rest] -> rest
      parts -> parts
    end
  end

  defp registered_instances do
    :persistent_term.get(@instance_registry_key, MapSet.new())
    |> normalize_instances()
  end

  defp with_instance_registry_lock(updater) when is_function(updater, 1) do
    with_instance_registry_lock(updater, @instance_registry_lock_retries)
  end

  defp with_instance_registry_lock(updater, retries_left)
       when is_function(updater, 1) and retries_left > 0 do
    result =
      :global.trans(@instance_registry_lock, fn ->
        instances = registered_instances()
        new_instances = updater.(instances) |> normalize_instances()
        :persistent_term.put(@instance_registry_key, new_instances)
        :ok
      end)

    case result do
      :ok -> :ok
      {:aborted, _reason} -> with_instance_registry_lock(updater, retries_left - 1)
      _other -> :ok
    end
  end

  defp with_instance_registry_lock(updater, 0) when is_function(updater, 1) do
    # Best-effort fallback to avoid hard failure if lock acquisition is transiently unavailable.
    instances = registered_instances()
    new_instances = updater.(instances) |> normalize_instances()
    :persistent_term.put(@instance_registry_key, new_instances)
    :ok
  end

  defp normalize_instances(%MapSet{} = instances), do: instances
  defp normalize_instances(instances) when is_list(instances), do: MapSet.new(instances)
  defp normalize_instances(_other), do: MapSet.new()
end
