defmodule Jido.Signal.Bus.DispatchPipelineTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus.DispatchPipeline
  alias Jido.Signal.Bus.Subscriber

  defmodule PassThroughMiddleware do
    @behaviour Jido.Signal.Bus.Middleware

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def before_dispatch(signal, _subscriber, _context, state) do
      {:cont, signal, state}
    end

    @impl true
    def after_dispatch(_signal, _subscriber, _result, _context, state) do
      {:cont, Map.put(state, :after_dispatch_called, true)}
    end
  end

  defmodule SkipDispatchMiddleware do
    @behaviour Jido.Signal.Bus.Middleware

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def before_dispatch(_signal, _subscriber, _context, state) do
      {:skip, state}
    end
  end

  defmodule ErrorDispatchMiddleware do
    @behaviour Jido.Signal.Bus.Middleware

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def before_dispatch(_signal, _subscriber, _context, state) do
      {:halt, :middleware_halt, state}
    end
  end

  defp signal(type) do
    Signal.new!(%{
      type: type,
      source: "/test",
      data: %{value: type}
    })
  end

  defp context do
    %{
      bus_name: :dispatch_pipeline_test_bus,
      timestamp: DateTime.utc_now(),
      metadata: %{}
    }
  end

  defp subscription(id) do
    %Subscriber{
      id: id,
      path: "test.**",
      dispatch: {:noop, []},
      persistent?: false,
      persistence_pid: nil,
      created_at: DateTime.utc_now()
    }
  end

  test "dispatch_with_middleware/8 dispatches and updates middleware on success" do
    middleware = [{PassThroughMiddleware, %{before: true}}]
    signal = signal("test.dispatch.ok")
    signal_id = signal.id
    subscriber = subscription("sub-ok")
    parent = self()

    dispatch_fun = fn processed_signal, _subscription ->
      send(parent, {:dispatch_called, processed_signal.id})
      :ok
    end

    assert {:dispatch, [{PassThroughMiddleware, updated_state}], :ok} =
             DispatchPipeline.dispatch_with_middleware(
               middleware,
               signal,
               subscriber.id,
               subscriber,
               context(),
               1_000,
               dispatch_fun,
               %{bus_name: :dispatch_pipeline_test_bus}
             )

    assert updated_state[:after_dispatch_called] == true
    assert_receive {:dispatch_called, ^signal_id}, 200
  end

  test "dispatch_with_middleware/8 skips dispatch when middleware requests skip" do
    middleware = [{SkipDispatchMiddleware, %{before: true}}]
    signal = signal("test.dispatch.skip")
    subscriber = subscription("sub-skip")
    parent = self()

    dispatch_fun = fn _processed_signal, _subscription ->
      send(parent, :dispatch_called)
      :ok
    end

    assert {:skip, [{SkipDispatchMiddleware, _state}]} =
             DispatchPipeline.dispatch_with_middleware(
               middleware,
               signal,
               subscriber.id,
               subscriber,
               context(),
               1_000,
               dispatch_fun,
               %{bus_name: :dispatch_pipeline_test_bus}
             )

    refute_receive :dispatch_called, 100
  end

  test "dispatch_with_middleware/8 returns middleware_error when middleware halts" do
    middleware = [{ErrorDispatchMiddleware, %{before: true}}]
    signal = signal("test.dispatch.error")
    subscriber = subscription("sub-error")
    parent = self()

    dispatch_fun = fn _processed_signal, _subscription ->
      send(parent, :dispatch_called)
      :ok
    end

    assert {:middleware_error, [{ErrorDispatchMiddleware, _state}], :middleware_halt} =
             DispatchPipeline.dispatch_with_middleware(
               middleware,
               signal,
               subscriber.id,
               subscriber,
               context(),
               1_000,
               dispatch_fun,
               %{bus_name: :dispatch_pipeline_test_bus}
             )

    refute_receive :dispatch_called, 100
  end
end
