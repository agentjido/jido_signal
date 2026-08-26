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

  The instance name must be a fixed module or atom from application code. Do
  not create instance names from tenant IDs or other runtime input. The scoped
  process names are atoms and remain in the VM atom table.

  ## Child Processes

  Each instance starts:
  - Registry (for named Signal Buses)

  """

  alias Jido.Signal.Names

  @options_schema Zoi.keyword(
                    [
                      name:
                        Zoi.atom()
                        |> Zoi.refine({__MODULE__, :not_nil?, []})
                        |> Zoi.required(),
                      shutdown:
                        Zoi.union([Zoi.integer() |> Zoi.min(0), Zoi.literal(:infinity)])
                        |> Zoi.default(5_000)
                    ],
                    unrecognized_keys: :error
                  )

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
    validated_opts = validate_options!(opts)
    name = Keyword.fetch!(validated_opts, :name)
    shutdown = Keyword.fetch!(validated_opts, :shutdown)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [validated_opts]},
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
  @spec start_link([option()]) ::
          {:ok, pid()} | {:error, term()} | {:error, {:invalid_options, String.t()}}
  def start_link(opts) do
    with {:ok, validated_opts} <- validate_options(opts) do
      name = Keyword.fetch!(validated_opts, :name)
      instance_opts = [jido: name]

      children = [{Registry, keys: :unique, name: Names.registry(instance_opts)}]

      supervisor_name = Names.supervisor(instance_opts)
      Supervisor.start_link(children, strategy: :one_for_one, name: supervisor_name)
    end
  end

  @doc false
  def not_nil?(nil, _context), do: {:error, "must not be nil"}
  def not_nil?(_name, _context), do: :ok

  @doc """
  Checks if an instance is running.

  ## Examples

      iex> Jido.Signal.Instance.running?(MyApp.Jido)
      true

  """
  @spec running?(atom()) :: boolean()
  def running?(instance) when is_atom(instance) do
    instance_opts = [jido: instance]
    supervisor_name = Names.supervisor(instance_opts)

    case Process.whereis(supervisor_name) do
      nil -> false
      pid when is_pid(pid) -> Process.alive?(pid)
    end
  end

  @doc """
  Stops an instance supervisor.

  ## Examples

      :ok = Jido.Signal.Instance.stop(MyApp.Jido)

  """
  @spec stop(atom(), timeout()) :: :ok
  def stop(instance, timeout \\ 5000) when is_atom(instance) do
    instance_opts = [jido: instance]
    supervisor_name = Names.supervisor(instance_opts)

    case Process.whereis(supervisor_name) do
      nil ->
        :ok

      pid ->
        try do
          Supervisor.stop(pid, :normal, timeout)
        catch
          :exit, :noproc -> :ok
          :exit, {:noproc, _details} -> :ok
        end
    end
  end

  defp validate_options(opts) do
    case Zoi.parse(@options_schema, opts) do
      {:ok, validated_opts} -> {:ok, validated_opts}
      {:error, errors} -> {:error, {:invalid_options, Zoi.prettify_errors(errors)}}
    end
  end

  defp validate_options!(opts) do
    case validate_options(opts) do
      {:ok, validated_opts} -> validated_opts
      {:error, {:invalid_options, message}} -> raise ArgumentError, message
    end
  end
end
