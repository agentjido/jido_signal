defmodule Jido.Signal.Util do
  @moduledoc """
  A collection of utility functions for the Jido framework.

  This module provides various helper functions that are used throughout the Jido framework,
  including:

  - ID generation
  - Name validation
  - Error handling
  - Logging utilities

  These utilities are designed to support common operations and maintain consistency
  across the Jido ecosystem. They encapsulate frequently used patterns and provide
  a centralized location for shared functionality.

  Many of the functions in this module are used internally by other Jido modules,
  but they can also be useful for developers building applications with Jido.
  """

  alias Jido.Signal.Names

  require Logger

  @type server :: pid() | atom() | binary() | {name :: atom() | binary(), registry :: module()}

  @doc """
  Creates a via tuple for process registration with a registry.

  ## Parameters

  - name: The name to register (atom, string, or {name, registry} tuple)
  - opts: Options list
    - :registry - The registry module to use (defaults to Jido.Signal.Registry)

  ## Returns

  A via tuple for use with process registration

  ## Examples

      iex> Jido.Signal.Util.via_tuple(:my_process)
      {:via, Registry, {Jido.Signal.Registry, "my_process"}}

      iex> Jido.Signal.Util.via_tuple(:my_process, registry: MyRegistry)
      {:via, Registry, {MyRegistry, "my_process"}}

      iex> Jido.Signal.Util.via_tuple({:my_process, MyRegistry})
      {:via, Registry, {MyRegistry, "my_process"}}

      iex> Jido.Signal.Util.via_tuple(:my_process, jido: MyApp.Jido)
      {:via, Registry, {MyApp.Jido.Signal.Registry, "my_process"}}

  """
  @spec via_tuple(server(), keyword()) :: {:via, Registry, {module(), String.t()}}
  def via_tuple(name_or_tuple, opts \\ [])

  def via_tuple({name, registry}, _opts) when is_atom(registry) do
    name = if is_atom(name), do: Atom.to_string(name), else: name
    {:via, Registry, {registry, name}}
  end

  def via_tuple(name, opts) do
    # Use jido: option for instance-scoped registry, fall back to explicit :registry option
    registry =
      case Keyword.get(opts, :jido) do
        nil -> Keyword.get(opts, :registry, Jido.Signal.Registry)
        _instance -> Names.registry(opts)
      end

    name = if is_atom(name), do: Atom.to_string(name), else: name
    {:via, Registry, {registry, name}}
  end

  @doc """
  Finds a process by name, pid, or {name, registry} tuple.

  ## Parameters

  - server: The process identifier (pid, name, or {name, registry} tuple)
  - opts: Options list
    - :registry - The registry module to use (defaults to Jido.Signal.Registry)

  ## Returns

  - `{:ok, pid}` if process is found
  - `{:error, :not_found}` if process is not found

  ## Examples

      iex> Jido.Signal.Util.whereis(pid)
      {:ok, #PID<0.123.0>}

      iex> Jido.Signal.Util.whereis(:my_process)
      {:ok, #PID<0.124.0>}

      iex> Jido.Signal.Util.whereis({:my_process, MyRegistry})
      {:ok, #PID<0.125.0>}

      iex> Jido.Signal.Util.whereis(:my_process, jido: MyApp.Jido)
      {:ok, #PID<0.126.0>}
  """
  @spec whereis(server(), keyword()) :: {:ok, pid()} | {:error, :not_found}
  def whereis(server, opts \\ [])

  def whereis(pid, _opts) when is_pid(pid), do: {:ok, pid}

  def whereis({name, registry}, _opts) when is_atom(registry) do
    name = if is_atom(name), do: Atom.to_string(name), else: name

    case Registry.lookup(registry, name) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  def whereis(name, opts) do
    # Use jido: option for instance-scoped registry, fall back to explicit :registry option
    registry =
      case Keyword.get(opts, :jido) do
        nil -> Keyword.get(opts, :registry, Jido.Signal.Registry)
        _instance -> Names.registry(opts)
      end

    name = if is_atom(name), do: Atom.to_string(name), else: name

    case Registry.lookup(registry, name) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Returns the package-default execution log level.
  """
  @spec default_log_level() :: Logger.level()
  def default_log_level do
    Application.get_env(:jido_signal, :default_log_level, :info)
    |> normalize_log_level(:info)
  end

  @doc """
  Resolves a per-call execution log level with package defaults.

  Precedence:
    1. `opts[:log_level]`
    2. `opts[:level]` (legacy compatibility)
    3. `config :jido_signal, default_log_level: ...`
    4. built-in `:info`
  """
  @spec resolve_log_level(keyword()) :: Logger.level()
  def resolve_log_level(opts \\ []) when is_list(opts) do
    opts
    |> Keyword.get(:log_level, Keyword.get(opts, :level, default_log_level()))
    |> normalize_log_level(default_log_level())
  end

  @doc """
  Conditionally emits a log message based on a threshold level.
  """
  @spec cond_log(Logger.level(), Logger.level(), Logger.message(), keyword()) :: :ok
  def cond_log(threshold_level, message_level, message, metadata \\ []) do
    threshold_level = normalize_log_level(threshold_level, default_log_level())
    message_level = normalize_log_level(message_level, :info)

    if Logger.compare_levels(threshold_level, message_level) in [:lt, :eq] do
      Logger.log(message_level, message, metadata)
    else
      :ok
    end
  end

  defp normalize_log_level(level, _fallback) when level in [:debug, :info, :warning, :error],
    do: level

  defp normalize_log_level(_level, fallback), do: fallback
end
