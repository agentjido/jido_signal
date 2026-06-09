defmodule Jido.Signal.Dispatch.CircuitBreaker do
  @moduledoc """
  Circuit breaker wrapper for dispatch adapters.

  Circuits are per breaker server and adapter type. The default application server
  provides global dispatch protection, and instance supervisors can start their own
  breaker server for isolated runtime dispatch.

  ## Configuration

  Default settings:
  - More than 5 failures in 10 seconds triggers the circuit to open
  - 30 second reset time before trying again

  ## Usage

      # Install circuit for an adapter type
      :ok = CircuitBreaker.install(:http)

      # Run a function with circuit breaker protection
      case CircuitBreaker.run(:http, fn -> make_request() end) do
        :ok -> :ok
        {:ok, response} -> {:ok, response}
        {:error, :circuit_open} -> {:error, :circuit_open}
        {:error, reason} -> {:error, reason}
      end

      # Check status
      :ok = CircuitBreaker.status(:http)  # or :blown

      # Reset manually
      :ok = CircuitBreaker.reset(:http)
  """

  alias Jido.Signal.Dispatch.CircuitBreaker.Server
  alias Jido.Signal.Telemetry

  @default_max_failures 5
  @default_window_ms 10_000
  @default_reset_ms 30_000
  @valid_install_opts [:strategy, :refresh, :server]
  @valid_scope_opts [:server]

  @type scope_opts :: [server: atom()]
  @type install_opts :: [
          strategy: {:standard, non_neg_integer(), non_neg_integer()},
          refresh: non_neg_integer(),
          server: atom()
        ]

  @doc """
  Installs a circuit breaker for the given adapter type.

  Should be called once at application startup for each adapter type that needs protection.
  Repeated installs with the same configuration are no-ops; installs with changed
  configuration reset the circuit with the new settings.

  ## Parameters

  * `adapter_type` - Atom identifying the adapter (e.g., `:http`, `:webhook`)
  * `opts` - Optional configuration:
    * `:strategy` - Circuit strategy, defaults to `{:standard, 5, 10_000}` (tolerate 5 failures in 10 seconds)
    * `:refresh` - Reset time in milliseconds, defaults to 30_000
    * `:server` - Optional breaker server name. Defaults to the global server.

  ## Returns

  * `:ok` - Circuit installed successfully
  * `{:error, term()}` - Installation failed
  """
  @spec install(atom(), install_opts()) :: :ok | {:error, term()}
  def install(adapter_type, opts \\ []) do
    with {:ok, config, server} <- config(opts) do
      Server.install(server, circuit_name(adapter_type), config)
    end
  end

  @doc false
  @spec ensure_installed(atom(), install_opts()) :: :ok | {:error, term()}
  def ensure_installed(adapter_type, opts \\ []) do
    with {:ok, _config, server} <- config(opts) do
      case Server.status(server, circuit_name(adapter_type)) do
        {:error, :not_found} -> install(adapter_type, opts)
        {:error, _reason} = error -> error
        _status -> :ok
      end
    end
  end

  @doc """
  Runs a function with circuit breaker protection.

  Returns the function result if the circuit is closed, or `{:error, :circuit_open}` if open.
  On failure, the circuit records the failure.

  ## Parameters

  * `adapter_type` - Atom identifying the adapter
  * `fun` - Zero-arity function to execute
  * `opts` - Optional scope options:
    * `:server` - Optional breaker server name. Defaults to the global server.

  ## Returns

  * Result of `fun` if circuit is closed and execution succeeds
  * `{:error, :circuit_open}` if circuit is open
  * `{:error, {:exception, message}}` if function raises
  """
  @spec run(atom(), (-> any()), scope_opts()) :: any() | {:error, term()}
  def run(adapter_type, fun, opts \\ []) when is_function(fun, 0) do
    with {:ok, server} <- scope(opts) do
      do_run(adapter_type, fun, server)
    end
  end

  defp do_run(adapter_type, fun, server) do
    circuit = circuit_name(adapter_type)

    case Server.status(server, circuit) do
      :ok ->
        try do
          result = fun.()

          case result do
            :ok ->
              result

            {:ok, _} = ok ->
              ok

            {:error, _} = error ->
              _ = Server.melt(server, circuit)
              emit_melt_telemetry(adapter_type, server)
              error
          end
        rescue
          e ->
            _ = Server.melt(server, circuit)
            emit_melt_telemetry(adapter_type, server)
            {:error, {:exception, Exception.message(e)}}
        end

      :blown ->
        emit_rejected_telemetry(adapter_type, server)
        {:error, :circuit_open}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the current status of a circuit.

  ## Parameters

  * `adapter_type` - Atom identifying the adapter
  * `opts` - Optional scope options:
    * `:server` - Optional breaker server name. Defaults to the global server.

  ## Returns

  * `:ok` - Circuit is closed (healthy)
  * `:blown` - Circuit is open (failing)
  """
  @spec status(atom(), scope_opts()) :: :ok | :blown | {:error, term()}
  def status(adapter_type, opts \\ []) do
    with {:ok, server} <- scope(opts) do
      Server.status(server, circuit_name(adapter_type))
    end
  end

  @doc """
  Resets a circuit, allowing requests through again.

  ## Parameters

  * `adapter_type` - Atom identifying the adapter
  * `opts` - Optional scope options:
    * `:server` - Optional breaker server name. Defaults to the global server.

  ## Returns

  * `:ok` - Circuit reset successfully
  """
  @spec reset(atom(), scope_opts()) :: :ok | {:error, term()}
  def reset(adapter_type, opts \\ []) do
    with {:ok, server} <- scope(opts) do
      result = Server.reset(server, circuit_name(adapter_type))

      if result == :ok do
        emit_reset_telemetry(adapter_type, server)
      end

      result
    end
  end

  @doc """
  Checks if a circuit is installed.

  ## Parameters

  * `adapter_type` - Atom identifying the adapter
  * `opts` - Optional scope options:
    * `:server` - Optional breaker server name. Defaults to the global server.

  ## Returns

  * `true` - Circuit is installed
  * `false` - Circuit is not installed
  """
  @spec installed?(atom(), scope_opts()) :: boolean()
  def installed?(adapter_type, opts \\ []) do
    case status(adapter_type, opts) do
      :ok -> true
      :blown -> true
      {:error, _reason} -> false
    end
  end

  defp circuit_name(adapter_type) when is_atom(adapter_type) do
    adapter_type
  end

  defp config(opts) when is_list(opts) do
    with :ok <- validate_option_keys(opts, @valid_install_opts),
         {:ok, server} <- validate_server(Keyword.get(opts, :server, Server)),
         {:ok, max_failures, window_ms} <-
           validate_strategy(
             Keyword.get(opts, :strategy, {:standard, @default_max_failures, @default_window_ms})
           ),
         {:ok, refresh_ms} <- validate_refresh(Keyword.get(opts, :refresh, @default_reset_ms)) do
      {:ok, %{max_failures: max_failures, window_ms: window_ms, refresh_ms: refresh_ms}, server}
    end
  end

  defp config(opts), do: {:error, {:invalid_options, opts}}

  defp scope(opts) when is_list(opts) do
    case validate_option_keys(opts, @valid_scope_opts) do
      :ok -> validate_server(Keyword.get(opts, :server, Server))
      error -> error
    end
  end

  defp scope(opts), do: {:error, {:invalid_options, opts}}

  defp validate_option_keys(opts, valid_keys) do
    invalid_keys = opts |> Keyword.keys() |> Enum.reject(&(&1 in valid_keys))

    case invalid_keys do
      [] -> :ok
      _keys -> {:error, {:invalid_options, invalid_keys}}
    end
  end

  defp validate_server(server) when is_atom(server), do: {:ok, server}
  defp validate_server(server), do: {:error, {:invalid_server, server}}

  defp validate_strategy({:standard, max_failures, window_ms})
       when is_integer(max_failures) and max_failures >= 0 and is_integer(window_ms) and
              window_ms >= 0 do
    {:ok, max_failures, window_ms}
  end

  defp validate_strategy(strategy), do: {:error, {:invalid_strategy, strategy}}

  defp validate_refresh(refresh_ms) when is_integer(refresh_ms) and refresh_ms >= 0 do
    {:ok, refresh_ms}
  end

  defp validate_refresh(refresh_ms), do: {:error, {:invalid_refresh, refresh_ms}}

  defp emit_melt_telemetry(adapter_type, server) do
    Telemetry.execute(
      [:jido, :dispatch, :circuit, :melt],
      %{},
      %{adapter: adapter_type, server: server}
    )
  end

  defp emit_rejected_telemetry(adapter_type, server) do
    Telemetry.execute(
      [:jido, :dispatch, :circuit, :rejected],
      %{},
      %{adapter: adapter_type, server: server}
    )
  end

  defp emit_reset_telemetry(adapter_type, server) do
    Telemetry.execute(
      [:jido, :dispatch, :circuit, :reset],
      %{},
      %{adapter: adapter_type, server: server}
    )
  end
end
