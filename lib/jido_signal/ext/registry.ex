defmodule Jido.Signal.Ext.Registry do
  @moduledoc """
  Compile-time registry for Signal extensions.

  This module provides a centralized registry for all Signal extensions,
  enabling runtime lookup and validation. Extensions are automatically
  registered during compilation through the `@after_compile` hook in
  the `Jido.Signal.Ext` behavior.

  ## Overview

  The registry maintains a mapping between extension namespaces and their
  implementing modules. This allows the Signal system to:

  - Validate extension data at runtime
  - Look up extension modules by namespace
  - Enumerate all available extensions
  - Handle extension serialization/deserialization

  ## Storage Mechanism

  The registry uses an Agent for thread-safe storage during development
  and testing. In production, this could be backed by ETS for better
  performance with many concurrent readers.

  ## Registration Process

  Extensions are automatically registered when they are compiled:

      defmodule MyApp.Auth do
        use Jido.Signal.Ext,
          namespace: "auth",
          schema: [user_id: [type: :string, required: true]]
      end

      # After compilation, the extension is automatically available:
      {:ok, MyApp.Auth} = Jido.Signal.Ext.Registry.get("auth")

  ## Thread Safety

  All registry operations are thread-safe and can be called concurrently
  from multiple processes without coordination.

  ## Error Handling

  The registry uses standard Elixir conventions:
  - Returns `{:ok, result}` for successful operations
  - Returns `{:error, reason}` for failures
  - Provides bang versions that raise on errors

  ## Examples

      # Look up an extension by namespace
      case Jido.Signal.Ext.Registry.get("auth") do
        {:ok, module} -> module.validate_data(auth_data)
        {:error, :not_found} -> handle_unknown_extension()
      end

      # Get all registered extensions
      extensions = Jido.Signal.Ext.Registry.all()
      IO.puts("Found \#{length(extensions)} extensions")

      # Check if an extension is registered
      if Jido.Signal.Ext.Registry.get!("tracking") do
        apply_tracking_extension()
      end
  """
  use GenServer

  alias Jido.Signal.Names

  require Logger

  @registry_name __MODULE__

  # Client API

  @doc """
  Returns a child_spec for starting the registry under a supervisor.

  ## Options

    * `:name` - The name to register the process under (default: #{@registry_name})

  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, @registry_name)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  @doc """
  Starts the extension registry.

  This is typically called by the application supervision tree
  and doesn't need to be called manually.

  ## Options

    * `:name` - The name to register the process under (default: #{@registry_name})

  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @registry_name)
    GenServer.start_link(__MODULE__, %{name: name}, Keyword.put(opts, :name, name))
  end

  @doc """
  Registers an extension module with its namespace.

  This function is typically called automatically by the `@after_compile`
  hook in extension modules and doesn't need to be called manually.

  ## Parameters
  - `module` - The extension module to register

  ## Returns
  `:ok` if registration succeeds, `:ok` if registry is not available

  ## Examples

      # Automatic registration (preferred)
      defmodule MyExt do
        use Jido.Signal.Ext, namespace: "my_ext"
      end

      # Manual registration (not typically needed)
      Jido.Signal.Ext.Registry.register(MyExt)
  """
  @spec register(module(), keyword()) :: :ok
  def register(module, opts \\ []) when is_atom(module) do
    namespace = module.namespace()
    registry_name = registry_name_for_register(opts)

    # Handle the case where the registry process is not started (e.g., during compilation)
    try do
      GenServer.call(registry_name, {:register, namespace, module})
    catch
      :exit, {:noproc, _} ->
        Logger.debug("Extension registry not started, skipping registration of #{module}")
        queue_pending(registry_name, module)
        :ok

      :exit, {:timeout, _} ->
        Logger.debug("Extension registry timeout, skipping registration of #{module}")
        queue_pending(registry_name, module)
        :ok
    end
  end

  @doc """
  Looks up an extension module by namespace.

  ## Parameters
  - `namespace` - The extension namespace string

  ## Returns
  `{:ok, module}` if found, `{:error, :not_found}` otherwise

  ## Examples

      case Jido.Signal.Ext.Registry.get("auth") do
        {:ok, AuthExt} ->
          {:ok, data} = AuthExt.validate_data(%{user_id: "123"})
        {:error, :not_found} ->
          {:error, "Unknown extension: auth"}
      end
  """
  @spec get(String.t(), keyword()) :: {:ok, module()} | {:error, :not_found}
  def get(namespace, opts \\ []) when is_binary(namespace) do
    case GenServer.call(registry_name(opts), {:get, namespace}) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Looks up an extension module by namespace, raising if not found.

  ## Parameters
  - `namespace` - The extension namespace string

  ## Returns
  The extension module

  ## Raises
  `ArgumentError` if the extension is not found

  ## Examples

      module = Jido.Signal.Ext.Registry.get!("auth")
      {:ok, data} = module.validate_data(%{user_id: "123"})
  """
  @spec get!(String.t(), keyword()) :: module() | no_return()
  def get!(namespace, opts \\ []) when is_binary(namespace) do
    case get(namespace, opts) do
      {:ok, module} -> module
      {:error, :not_found} -> raise ArgumentError, "Extension not found: #{namespace}"
    end
  end

  @doc """
  Returns all registered extensions.

  ## Returns
  A list of `{namespace, module}` tuples for all registered extensions

  ## Examples

      extensions = Jido.Signal.Ext.Registry.all()

      Enum.each(extensions, fn {namespace, module} ->
        IO.puts("Extension \#{namespace}: \#{module}")
      end)
  """
  @spec all(keyword()) :: [{String.t(), module()}]
  def all(opts \\ []) do
    GenServer.call(registry_name(opts), :all)
  end

  @doc """
  Returns the count of registered extensions.

  ## Examples

      count = Jido.Signal.Ext.Registry.count()
      IO.puts("\#{count} extensions registered")
  """
  @spec count(keyword()) :: non_neg_integer()
  def count(opts \\ []) do
    GenServer.call(registry_name(opts), :count)
  end

  @doc """
  Checks if an extension is registered for the given namespace.

  ## Parameters
  - `namespace` - The extension namespace string

  ## Returns
  `true` if registered, `false` otherwise

  ## Examples

      if Jido.Signal.Ext.Registry.registered?("auth") do
        # Use auth extension
      else
        # Handle missing extension
      end
  """
  @spec registered?(String.t(), keyword()) :: boolean()
  def registered?(namespace, opts \\ []) when is_binary(namespace) do
    case get(namespace, opts) do
      {:ok, _} -> true
      {:error, :not_found} -> false
    end
  end

  # Server Implementation

  @impl GenServer
  def init(%{name: name}) do
    {:ok, drain_pending(name)}
  end

  @impl GenServer
  def handle_call({:register, namespace, module}, _from, state) do
    case Map.get(state, namespace) do
      nil ->
        new_state = Map.put(state, namespace, module)
        {:reply, :ok, new_state}

      existing_module when existing_module == module ->
        # Same module re-registering (e.g., during hot reload)
        {:reply, :ok, state}

      existing_module ->
        # Different module trying to register same namespace
        Logger.warning(
          "Extension namespace '#{namespace}' already registered by #{existing_module}, ignoring registration of #{module}"
        )

        {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_call({:get, namespace}, _from, state) do
    case Map.fetch(state, namespace) do
      {:ok, module} -> {:reply, {:ok, module}, state}
      :error -> {:reply, :error, state}
    end
  end

  @impl GenServer
  def handle_call(:all, _from, state) do
    extensions = Enum.to_list(state)
    {:reply, extensions, state}
  end

  @impl GenServer
  def handle_call(:count, _from, state) do
    count = map_size(state)
    {:reply, count, state}
  end

  # Fallback for testing when the registry is not started
  def handle_call(request, from, state) do
    Logger.warning("Unhandled registry call: #{inspect(request)} from #{inspect(from)}")
    {:reply, {:error, :unknown_request}, state}
  end

  defp registry_name(opts) do
    if Keyword.has_key?(opts, :jido) do
      Names.ext_registry(opts)
    else
      @registry_name
    end
  end

  defp registry_name_for_register(opts) do
    if Keyword.has_key?(opts, :jido) do
      opts
      |> Keyword.put(:allow_unregistered?, true)
      |> Names.ext_registry()
    else
      @registry_name
    end
  end

  defp queue_pending(registry_name, module) do
    key = pending_key(registry_name)
    pending = :persistent_term.get(key, [])

    unless module in pending do
      :persistent_term.put(key, [module | pending])
    end
  end

  defp drain_pending(registry_name) do
    key = pending_key(registry_name)

    state =
      key
      |> :persistent_term.get([])
      |> Enum.reduce(%{}, fn module, acc ->
        if function_exported?(module, :namespace, 0) do
          Map.put_new(acc, module.namespace(), module)
        else
          acc
        end
      end)

    :persistent_term.erase(key)
    state
  end

  defp pending_key(registry_name), do: {__MODULE__, :pending, registry_name}
end
