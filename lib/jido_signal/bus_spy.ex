defmodule Jido.Signal.BusSpy do
  @moduledoc """
  A test utility for observing signals crossing process boundaries via telemetry events.

  The BusSpy allows test processes to capture the exact signals that travel across
  process boundaries through the Signal Bus without interfering with normal signal
  delivery. It integrates cleanly with existing cross-process test infrastructure.

  ## Usage

  ```elixir
  test "cross-process signal observation" do
    # Start the spy to capture bus events
    spy = BusSpy.start_spy()
    
    # Set up your cross-process test scenario
    %{producer: producer, consumer: consumer} = setup_cross_process_agents()
    
    # Send a signal that will cross process boundaries
    send_signal_sync(producer, :root, %{test_data: "cross-process"})
    
    # Wait for completion
    wait_for_cross_process_completion([consumer])
    
    # Verify the signal was observed crossing the bus
    dispatched_signals = BusSpy.get_dispatched_signals(spy)
    assert length(dispatched_signals) == 1
    
    [signal_event] = dispatched_signals
    assert signal_event.signal.type == "child.event"
    assert signal_event.signal.data.test_data == "cross-process"
    
    # Verify trace context was preserved
    assert signal_event.signal.trace_context != nil
    
    BusSpy.stop_spy(spy)
  end
  ```

  ## Events Captured

  The spy captures these telemetry events:
  - `[:jido, :signal, :bus, :before_dispatch]` - Before signal dispatch
  - `[:jido, :signal, :bus, :after_dispatch]` - After successful dispatch  
  - `[:jido, :signal, :bus, :dispatch_skipped]` - When middleware skips dispatch
  - `[:jido, :signal, :bus, :dispatch_error]` - When dispatch fails

  Each event includes full signal and subscription metadata for test verification.

  ## Lifecycle

  `BusSpy` is intended for test/runtime instrumentation and should be stopped with
  `stop_spy/1` so telemetry handlers are detached deterministically. As with all OTP
  processes, `:brutal_kill` bypasses `terminate/2`.
  """

  use GenServer

  alias Jido.Signal.Bus
  alias Jido.Signal.Telemetry

  @type spy_ref :: pid()
  @type signal_event :: %{
          event: atom(),
          timestamp: integer(),
          bus_name: atom(),
          signal_id: String.t(),
          signal_type: String.t(),
          subscription_id: String.t(),
          subscription_path: String.t(),
          signal: Jido.Signal.t(),
          subscription: map(),
          dispatch_result: term() | nil,
          error: term() | nil,
          reason: atom() | nil
        }

  @events [
    [:jido, :signal, :bus, :before_dispatch],
    [:jido, :signal, :bus, :after_dispatch],
    [:jido, :signal, :bus, :dispatch_skipped],
    [:jido, :signal, :bus, :dispatch_error]
  ]

  @doc """
  Starts a new bus spy process to collect telemetry events.

  This compatibility API starts the spy directly. For deterministic lifecycle in tests,
  prefer `start_supervised_spy/1`.

  Returns a spy reference that can be used to query captured events.
  """
  @spec start_spy() :: spy_ref()
  def start_spy do
    {:ok, pid} = start_link([])
    pid
  end

  @doc """
  Starts a bus spy under a dedicated supervisor.

  This helper is preferred for tests because stopping the returned supervisor
  deterministically stops the spy and detaches telemetry handlers.
  """
  @spec start_supervised_spy(keyword()) :: {:ok, spy_ref(), pid()} | {:error, term()}
  def start_supervised_spy(opts \\ []) do
    child_opts = Keyword.drop(opts, [:supervisor_name])
    supervisor_name = Keyword.get(opts, :supervisor_name)

    supervisor_opts =
      [strategy: :one_for_one]
      |> maybe_put_supervisor_name(supervisor_name)

    with {:ok, supervisor_pid} <-
           Supervisor.start_link([{__MODULE__, child_opts}], supervisor_opts),
         {:ok, spy_pid} <- supervised_spy_pid(supervisor_pid) do
      {:ok, spy_pid, supervisor_pid}
    end
  end

  @doc """
  Starts a BusSpy process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    genserver_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  @doc """
  Returns a child specification for supervised startup.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name)

    %{
      id: if(is_nil(name), do: {__MODULE__, make_ref()}, else: {__MODULE__, name}),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary,
      shutdown: 5_000
    }
  end

  @doc """
  Stops a bus spy process and cleans up telemetry handlers.
  """
  @spec stop_spy(spy_ref()) :: :ok
  def stop_spy(spy_ref) do
    GenServer.stop(spy_ref)
  end

  @doc """
  Gets all signals that have been dispatched through the bus since the spy started.

  Returns a list of signal events in chronological order.
  """
  @spec get_dispatched_signals(spy_ref()) :: [signal_event()]
  def get_dispatched_signals(spy_ref) do
    GenServer.call(spy_ref, :get_dispatched_signals)
  end

  @doc """
  Gets signals that match a specific signal type pattern.

  ## Examples

      # Get all "user.*" events
      user_events = BusSpy.get_signals_by_type(spy, "user.*")
      
      # Get exact matches
      child_events = BusSpy.get_signals_by_type(spy, "child.event")
  """
  @spec get_signals_by_type(spy_ref(), String.t()) :: [signal_event()]
  def get_signals_by_type(spy_ref, signal_type_pattern) do
    GenServer.call(spy_ref, {:get_signals_by_type, signal_type_pattern})
  end

  @doc """
  Gets the most recent signal event for a specific bus.
  """
  @spec get_latest_signal(spy_ref(), atom()) :: signal_event() | nil
  def get_latest_signal(spy_ref, bus_name) do
    GenServer.call(spy_ref, {:get_latest_signal, bus_name})
  end

  @doc """
  Waits for a signal matching the given type pattern to be dispatched.

  Returns the matching signal event or times out.
  """
  @spec wait_for_signal(spy_ref(), String.t(), non_neg_integer()) ::
          {:ok, signal_event()} | :timeout
  def wait_for_signal(spy_ref, signal_type_pattern, timeout \\ 5000) do
    GenServer.call(spy_ref, {:wait_for_signal, signal_type_pattern, timeout}, timeout + 1000)
  end

  @doc """
  Clears all captured events from the spy.
  """
  @spec clear_events(spy_ref()) :: :ok
  def clear_events(spy_ref) do
    GenServer.call(spy_ref, :clear_events)
  end

  # GenServer Implementation

  def init(_opts) do
    previous_payload_setting =
      Application.get_env(:jido_signal, :telemetry_include_payload, :__unset__)

    Application.put_env(:jido_signal, :telemetry_include_payload, true)

    # Attach telemetry handlers for all bus events
    for event <- @events do
      handler_id = {__MODULE__, self(), event}

      Telemetry.attach(
        handler_id,
        event,
        &handle_telemetry_event/4,
        %{spy_pid: self(), handler_id: handler_id}
      )
    end

    {:ok, %{events: [], waiters: [], previous_payload_setting: previous_payload_setting}}
  end

  def handle_call(:get_dispatched_signals, _from, state) do
    # Return events in chronological order (oldest first)
    events = Enum.reverse(state.events)
    {:reply, events, state}
  end

  def handle_call({:get_signals_by_type, pattern}, _from, state) do
    matching_events =
      state.events
      |> Enum.reverse()
      |> Enum.filter(fn event ->
        match_signal_type?(event.signal_type, pattern)
      end)

    {:reply, matching_events, state}
  end

  def handle_call({:get_latest_signal, bus_name}, _from, state) do
    latest_event =
      Enum.find(state.events, fn event ->
        event.bus_name == bus_name
      end)

    {:reply, latest_event, state}
  end

  def handle_call({:wait_for_signal, pattern, timeout}, from, state) do
    # Check if we already have a matching signal
    case Enum.find(Enum.reverse(state.events), &match_signal_type?(&1.signal_type, pattern)) do
      nil ->
        # Add to waiters list and set timeout
        ref = Process.monitor(elem(from, 0))
        timer_ref = Process.send_after(self(), {:wait_timeout, ref}, timeout)
        waiter = %{from: from, pattern: pattern, ref: ref, timer_ref: timer_ref}
        {:noreply, %{state | waiters: [waiter | state.waiters]}}

      event ->
        {:reply, {:ok, event}, state}
    end
  end

  def handle_call(:clear_events, _from, state) do
    {:reply, :ok, %{state | events: []}}
  end

  def handle_info({:telemetry_event, event_name, measurements, metadata}, state) do
    bus_name = Map.get(metadata, :bus_name)
    subscription_id = Map.get(metadata, :subscription_id)
    signal_id = Map.get(metadata, :signal_id)
    bus_state = maybe_get_bus_state(bus_name)

    signal =
      Map.get(metadata, :signal) ||
        find_signal_in_bus_state(bus_state, signal_id)

    subscription =
      Map.get(metadata, :subscription) ||
        find_subscription_in_bus_state(bus_state, subscription_id)

    # Convert telemetry event to our signal event format
    signal_event = %{
      event: List.last(event_name),
      timestamp: Map.get(measurements, :timestamp, System.monotonic_time(:microsecond)),
      bus_name: bus_name,
      signal_id: signal_id,
      signal_type: Map.get(metadata, :signal_type),
      subscription_id: subscription_id,
      subscription_path: Map.get(metadata, :subscription_path),
      signal: signal,
      subscription: subscription,
      dispatch_result: Map.get(metadata, :dispatch_result),
      error: Map.get(metadata, :error),
      reason: Map.get(metadata, :reason)
    }

    # Add to events (newest first for efficient prepending)
    new_events = [signal_event | state.events]

    # Check if any waiters are satisfied
    {satisfied_waiters, remaining_waiters} =
      Enum.split_with(state.waiters, fn waiter ->
        match_signal_type?(signal_event.signal_type, waiter.pattern)
      end)

    # Reply to satisfied waiters
    for waiter <- satisfied_waiters do
      GenServer.reply(waiter.from, {:ok, signal_event})
      cancel_waiter_timer(waiter)
      Process.demonitor(waiter.ref, [:flush])
    end

    {:noreply, %{state | events: new_events, waiters: remaining_waiters}}
  end

  def handle_info({:wait_timeout, ref}, state) do
    # Find and remove the waiter, reply with timeout
    case Enum.find(state.waiters, &(&1.ref == ref)) do
      nil ->
        {:noreply, state}

      waiter ->
        GenServer.reply(waiter.from, :timeout)
        Process.demonitor(ref, [:flush])
        remaining_waiters = Enum.reject(state.waiters, &(&1.ref == ref))
        {:noreply, %{state | waiters: remaining_waiters}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # Remove any waiters for the dead process and cancel their timers.
    {removed_waiters, remaining_waiters} =
      Enum.split_with(state.waiters, fn waiter -> waiter.ref == ref end)

    Enum.each(removed_waiters, &cancel_waiter_timer/1)
    {:noreply, %{state | waiters: remaining_waiters}}
  end

  def terminate(_reason, state) do
    Enum.each(state.waiters, fn waiter ->
      cancel_waiter_timer(waiter)
      Process.demonitor(waiter.ref, [:flush])
    end)

    # Detach all telemetry handlers
    for event <- @events do
      Telemetry.detach({__MODULE__, self(), event})
    end

    restore_payload_setting(Map.get(state, :previous_payload_setting, :__unset__))

    :ok
  end

  # Telemetry event handler - forwards events to the spy process
  def handle_telemetry_event(
        event_name,
        measurements,
        metadata,
        %{spy_pid: spy_pid, handler_id: handler_id}
      ) do
    if Process.alive?(spy_pid) do
      send(spy_pid, {:telemetry_event, event_name, measurements, metadata})
    else
      Telemetry.detach(handler_id)
    end
  end

  # Simple glob-style pattern matching for signal types
  defp match_signal_type?(_signal_type, "*"), do: true
  defp match_signal_type?(signal_type, signal_type), do: true

  defp match_signal_type?(signal_type, pattern) do
    match_pattern_type(signal_type, pattern)
  end

  defp match_pattern_type(signal_type, pattern) do
    cond do
      String.ends_with?(pattern, "*") ->
        match_prefix_pattern(signal_type, pattern)

      String.starts_with?(pattern, "*") ->
        match_suffix_pattern(signal_type, pattern)

      String.contains?(pattern, "*") ->
        match_middle_pattern(signal_type, pattern)

      true ->
        false
    end
  end

  defp match_prefix_pattern(signal_type, pattern) do
    prefix = String.slice(pattern, 0..-2//1)
    String.starts_with?(signal_type, prefix)
  end

  defp match_suffix_pattern(signal_type, pattern) do
    suffix = String.slice(pattern, 1..-1//1)
    String.ends_with?(signal_type, suffix)
  end

  defp match_middle_pattern(signal_type, pattern) do
    case String.split(pattern, "*", parts: 2) do
      [prefix, suffix] ->
        String.starts_with?(signal_type, prefix) and String.ends_with?(signal_type, suffix)

      _ ->
        false
    end
  end

  defp cancel_waiter_timer(%{timer_ref: timer_ref}) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
  end

  defp cancel_waiter_timer(_waiter), do: false

  defp restore_payload_setting(:__unset__) do
    Application.delete_env(:jido_signal, :telemetry_include_payload)
  end

  defp restore_payload_setting(value) do
    Application.put_env(:jido_signal, :telemetry_include_payload, value)
  end

  defp maybe_get_bus_state(nil), do: nil

  defp maybe_get_bus_state(bus_name) do
    case Bus.whereis(bus_name) do
      {:ok, bus_pid} -> :sys.get_state(bus_pid)
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp find_signal_in_bus_state(nil, _signal_id), do: nil
  defp find_signal_in_bus_state(_bus_state, nil), do: nil

  defp find_signal_in_bus_state(%{log: log}, signal_id) when is_map(log) do
    Enum.find_value(log, fn {_log_id, signal} ->
      if Map.get(signal, :id) == signal_id, do: signal, else: nil
    end)
  end

  defp find_signal_in_bus_state(_, _), do: nil

  defp find_subscription_in_bus_state(nil, _subscription_id), do: nil
  defp find_subscription_in_bus_state(_bus_state, nil), do: nil

  defp find_subscription_in_bus_state(%{subscriptions: subscriptions}, subscription_id)
       when is_map(subscriptions) do
    Map.get(subscriptions, subscription_id)
  end

  defp find_subscription_in_bus_state(_, _), do: nil

  defp maybe_put_supervisor_name(opts, nil), do: opts
  defp maybe_put_supervisor_name(opts, name), do: Keyword.put(opts, :name, name)

  defp supervised_spy_pid(supervisor_pid) do
    case Supervisor.which_children(supervisor_pid) do
      [{_id, spy_pid, :worker, [__MODULE__]}] when is_pid(spy_pid) ->
        {:ok, spy_pid}

      _ ->
        {:error, :spy_child_not_found}
    end
  end
end
