defmodule Jido.Signal.Dispatch.TargetContractTest do
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
    assert_receive {:custom_signal, ^signal, first_opts}
    assert_receive {:custom_signal, ^signal, second_opts}
    assert first_opts[:sequence] == 1
    assert second_opts[:sequence] == 2
    assert first_opts[:validated]
    assert second_opts[:validated]
  end

  test "aggregates multi-target errors in target order" do
    signal = Signal.new!("dispatch.errors", %{}, source: "/test")
    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, _reason}

    targets = [
      {:pid, target: dead},
      {:named, target: {:name, :missing_dispatch_target}}
    ]

    assert {:error, [:process_not_alive, :process_not_found]} = Dispatch.dispatch(signal, targets)
  end

  test "does not expose removed runtime policy functions" do
    refute function_exported?(Dispatch, :dispatch_async, 2)
    refute function_exported?(Dispatch, :dispatch_batch, 3)
  end
end
