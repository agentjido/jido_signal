defmodule Jido.Signal.DispatchParallelTest do
  use ExUnit.Case

  alias Jido.Signal
  alias Jido.Signal.Dispatch

  defmodule SlowAdapter do
    @behaviour Jido.Signal.Dispatch.Adapter

    def validate_opts(opts), do: {:ok, opts}

    def deliver(_signal, opts) do
      delay = Keyword.get(opts, :delay, 100)
      Process.sleep(delay)
      :ok
    end
  end

  test "dispatches to multiple targets in parallel" do
    {:ok, signal} = Signal.new("test.event", %{})

    # 10 targets with 100ms delay each
    configs =
      for _i <- 1..10 do
        {SlowAdapter, [delay: 100]}
      end

    {elapsed_us, :ok} =
      :timer.tc(fn ->
        Dispatch.dispatch(signal, configs)
      end)

    elapsed_ms = div(elapsed_us, 1000)

    # With parallelism (max_concurrency: 8), should complete in ~200ms
    # Sequential would take ~1000ms
    assert elapsed_ms < 500, "Expected parallel execution, got #{elapsed_ms}ms"
  end

  test "returns all errors in a list" do
    {:ok, signal} = Signal.new("test.event", %{})

    configs = [
      {SlowAdapter, [delay: 50]},
      # Will error
      {:invalid_adapter, []},
      {SlowAdapter, [delay: 50]}
    ]

    assert {:error, [_error]} = Dispatch.dispatch(signal, configs)
  end

  test "returns all errors when multiple dispatches fail" do
    {:ok, signal} = Signal.new("test.event", %{})

    configs = [
      {SlowAdapter, [delay: 10]},
      {:invalid_adapter_1, []},
      {SlowAdapter, [delay: 10]},
      {:invalid_adapter_2, []},
      {:invalid_adapter_3, []}
    ]

    assert {:error, errors} = Dispatch.dispatch(signal, configs)
    # Should have 3 errors, not just the first one
    assert length(errors) == 3
  end
end
