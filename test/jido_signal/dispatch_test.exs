defmodule Jido.Signal.DispatchTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Dispatch

  defmodule CustomAdapter do
    @behaviour Jido.Signal.Dispatch.Adapter

    @impl true
    def options_schema do
      Zoi.keyword(
        [
          target: Zoi.pid() |> Zoi.required(),
          sequence: Zoi.integer() |> Zoi.required(),
          validated: Zoi.boolean() |> Zoi.default(true)
        ],
        unrecognized_keys: :error
      )
    end

    @impl true
    def deliver(signal, opts) do
      send(Keyword.fetch!(opts, :target), {:custom_signal, signal, opts})
      :ok
    end
  end

  defmodule CountingAdapter do
    @behaviour Jido.Signal.Dispatch.Adapter

    @impl true
    def options_schema do
      Zoi.keyword(
        [
          counter_pid:
            Zoi.pid()
            |> Zoi.refine({__MODULE__, :count_validation, []})
            |> Zoi.required()
        ],
        unrecognized_keys: :error
      )
    end

    def count_validation(pid, _opts) do
      send(pid, :validated)
      :ok
    end

    @impl true
    def deliver(_signal, _opts), do: :ok
  end

  test "normalizes and validates one tuple" do
    assert {:ok, {:pid, opts}} = Dispatch.validate_opts({:pid, target: self()})
    assert opts[:target] == self()
    assert opts[:delivery_mode] == :async
  end

  test "normalizes tuples before ordered synchronous delivery" do
    signal = Signal.new!("dispatch.ordered", %{}, source: "/test")

    targets = [
      {CustomAdapter, target: self(), sequence: 1},
      {CustomAdapter, target: self(), sequence: 2}
    ]

    assert :ok = Dispatch.dispatch(signal, targets)
    assert_received {:custom_signal, ^signal, first_opts}
    assert_received {:custom_signal, ^signal, second_opts}
    assert first_opts[:sequence] == 1
    assert second_opts[:sequence] == 2
    assert first_opts[:validated]
    assert second_opts[:validated]
  end

  test "aggregates multi-target errors in target order" do
    signal = Signal.new!("dispatch.errors", %{}, source: "/test")
    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, _reason}, 1_000

    targets = [
      {:pid, target: dead},
      {:named, target: {:name, :missing_dispatch_target}}
    ]

    assert {:error, [:process_not_alive, :process_not_found]} = Dispatch.dispatch(signal, targets)
  end

  test "rejects invalid targets in validation and delivery lists" do
    signal = Signal.new!("dispatch.invalid", %{}, source: "/test")

    assert {:error, :invalid_dispatch_config} =
             Dispatch.validate_opts([{:noop, []}, :invalid])

    assert {:error, [:invalid_dispatch_config]} =
             Dispatch.dispatch(signal, [{:noop, []}, :invalid])

    assert {:error, :invalid_dispatch_config} = Dispatch.dispatch(signal, :invalid)
    assert :ok = Dispatch.dispatch(signal, {nil, []})
  end

  test "does not expose removed runtime policy functions" do
    refute function_exported?(Dispatch, :dispatch_async, 2)
    refute function_exported?(Dispatch, :dispatch_batch, 3)
  end

  test "validates one target exactly once" do
    signal = Signal.new!("test.event", %{}, source: "/test")

    assert :ok = Dispatch.dispatch(signal, {CountingAdapter, counter_pid: self()})
    assert_received :validated
    refute_received :validated
  end

  test "validates each target exactly once" do
    signal = Signal.new!("test.event", %{}, source: "/test")

    configs =
      for _index <- 1..10 do
        {CountingAdapter, counter_pid: self()}
      end

    assert :ok = Dispatch.dispatch(signal, configs)

    for _index <- 1..10 do
      assert_received :validated
    end

    refute_received :validated
  end
end
