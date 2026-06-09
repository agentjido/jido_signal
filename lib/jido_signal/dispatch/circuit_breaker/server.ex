defmodule Jido.Signal.Dispatch.CircuitBreaker.Server do
  @moduledoc false

  use GenServer

  defmodule Circuit do
    @moduledoc false

    @enforce_keys [:name, :max_failures, :window_ms, :refresh_ms]
    defstruct [
      :name,
      :max_failures,
      :window_ms,
      :refresh_ms,
      :timer_ref,
      :timer_id,
      status: :ok,
      failures: []
    ]
  end

  @type server_name :: atom()
  @type circuit_name :: atom()
  @type config :: %{
          max_failures: non_neg_integer(),
          window_ms: non_neg_integer(),
          refresh_ms: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec install(server_name(), circuit_name(), config()) :: :ok | {:error, :server_not_found}
  def install(server, name, config) when is_atom(server) and is_atom(name) and is_map(config) do
    call(server, {:install, name, config}, {:error, :server_not_found})
  end

  @spec status(server_name(), circuit_name()) ::
          :ok | :blown | {:error, :not_found | :server_not_found}
  def status(server, name) when is_atom(server) and is_atom(name) do
    call(server, {:status, name}, {:error, :server_not_found})
  end

  @spec reset(server_name(), circuit_name()) :: :ok | {:error, :not_found | :server_not_found}
  def reset(server, name) when is_atom(server) and is_atom(name) do
    call(server, {:reset, name}, {:error, :server_not_found})
  end

  @spec melt(server_name(), circuit_name()) :: :ok
  def melt(server, name) when is_atom(server) and is_atom(name) do
    call(server, {:melt, name}, :ok)
  end

  @impl true
  def init(initial_state) do
    {:ok, initial_state}
  end

  defp call(server, request, fallback) do
    case Process.whereis(server) do
      nil ->
        fallback

      _pid ->
        GenServer.call(server, request)
    end
  catch
    :exit, {:noproc, _call} -> fallback
  end

  @impl true
  def handle_call({:install, name, config}, _from, circuits) do
    circuits =
      Map.update(circuits, name, new_circuit(name, config), fn circuit ->
        if same_config?(circuit, config) do
          circuit
        else
          cancel_timer(circuit)
          new_circuit(name, config)
        end
      end)

    {:reply, :ok, circuits}
  end

  def handle_call({:status, name}, _from, circuits) do
    reply =
      case Map.fetch(circuits, name) do
        {:ok, circuit} -> circuit.status
        :error -> {:error, :not_found}
      end

    {:reply, reply, circuits}
  end

  def handle_call({:reset, name}, _from, circuits) do
    case Map.fetch(circuits, name) do
      {:ok, circuit} ->
        {:reply, :ok, Map.put(circuits, name, reset_circuit(circuit))}

      :error ->
        {:reply, {:error, :not_found}, circuits}
    end
  end

  def handle_call({:melt, name}, _from, circuits) do
    case Map.fetch(circuits, name) do
      {:ok, circuit} ->
        circuit = record_failure(circuit, System.monotonic_time(:millisecond))
        {:reply, :ok, Map.put(circuits, name, circuit)}

      :error ->
        {:reply, :ok, circuits}
    end
  end

  @impl true
  def handle_info({:reset_circuit, name, timer_id}, circuits) do
    circuits =
      case Map.fetch(circuits, name) do
        {:ok, %Circuit{status: :blown, timer_id: ^timer_id} = circuit} ->
          Map.put(circuits, name, reset_circuit(circuit, :timer))

        _other ->
          circuits
      end

    {:noreply, circuits}
  end

  def handle_info(_message, circuits) do
    {:noreply, circuits}
  end

  defp new_circuit(name, config) do
    %Circuit{
      name: name,
      max_failures: config.max_failures,
      window_ms: config.window_ms,
      refresh_ms: config.refresh_ms
    }
  end

  defp same_config?(circuit, config) do
    circuit.max_failures == config.max_failures and
      circuit.window_ms == config.window_ms and
      circuit.refresh_ms == config.refresh_ms
  end

  defp record_failure(%Circuit{status: :blown} = circuit, _now), do: circuit

  defp record_failure(%Circuit{} = circuit, now) do
    failures =
      [now | circuit.failures]
      |> Enum.filter(fn failure_time -> now - failure_time < circuit.window_ms end)

    circuit = %Circuit{circuit | failures: failures}

    if length(failures) > circuit.max_failures do
      blow(circuit)
    else
      circuit
    end
  end

  defp blow(%Circuit{} = circuit) do
    timer_id = make_ref()

    timer_ref =
      Process.send_after(self(), {:reset_circuit, circuit.name, timer_id}, circuit.refresh_ms)

    %Circuit{circuit | status: :blown, timer_ref: timer_ref, timer_id: timer_id}
  end

  defp reset_circuit(circuit, source \\ :manual)

  defp reset_circuit(%Circuit{} = circuit, :manual) do
    cancel_timer(circuit)
    %Circuit{circuit | status: :ok, failures: [], timer_ref: nil, timer_id: nil}
  end

  defp reset_circuit(%Circuit{} = circuit, :timer) do
    %Circuit{circuit | status: :ok, failures: [], timer_ref: nil, timer_id: nil}
  end

  defp cancel_timer(%Circuit{timer_ref: nil}), do: :ok

  defp cancel_timer(%Circuit{timer_ref: timer_ref}) do
    _ = Process.cancel_timer(timer_ref)
    :ok
  end
end
