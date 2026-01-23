defmodule Jido.Signal.DispatchValidationTest do
  use ExUnit.Case

  alias Jido.Signal
  alias Jido.Signal.Dispatch

  defmodule CountingAdapter do
    @behaviour Jido.Signal.Dispatch.Adapter

    def validate_opts(opts) do
      # Increment counter
      pid = Keyword.fetch!(opts, :counter_pid)
      send(pid, :validated)
      {:ok, opts}
    end

    def deliver(_signal, _opts), do: :ok
  end

  test "validates options exactly once when pre-validated" do
    {:ok, signal} = Signal.new("test.event", %{})
    config = {CountingAdapter, [counter_pid: self()]}

    # Should validate once
    :ok = Dispatch.dispatch(signal, config)

    # Check exactly one validation
    assert_receive :validated
    refute_receive :validated, 100
  end

  test "validates options exactly once for multiple configs" do
    {:ok, signal} = Signal.new("test.event", %{})

    configs = [
      {CountingAdapter, [counter_pid: self()]},
      {CountingAdapter, [counter_pid: self()]},
      {CountingAdapter, [counter_pid: self()]}
    ]

    # Should validate exactly once per config (3 total)
    :ok = Dispatch.dispatch(signal, configs)

    # Check exactly three validations
    assert_receive :validated
    assert_receive :validated
    assert_receive :validated
    refute_receive :validated, 100
  end

  test "validates options exactly once in batch dispatch" do
    {:ok, signal} = Signal.new("test.event", %{})

    configs =
      for _i <- 1..10 do
        {CountingAdapter, [counter_pid: self()]}
      end

    # Should validate exactly once per config (10 total)
    :ok = Dispatch.dispatch_batch(signal, configs, batch_size: 5)

    # Check exactly ten validations
    for _i <- 1..10 do
      assert_receive :validated, 1000
    end

    refute_receive :validated, 100
  end
end
