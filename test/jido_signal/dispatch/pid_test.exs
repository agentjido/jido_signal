defmodule Jido.Signal.Dispatch.PidAdapterTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Dispatch
  alias Jido.Signal.Dispatch.PidAdapter

  test "async adapter delivery is best-effort and returns :ok for dead targets" do
    {:ok, signal} =
      Signal.new(%{
        type: "pid.adapter.async.dead",
        source: "/test",
        data: %{value: 1}
      })

    dead_pid =
      spawn(fn ->
        receive do
        after
          0 -> :ok
        end
      end)

    ref = Process.monitor(dead_pid)
    assert_receive {:DOWN, ^ref, :process, ^dead_pid, _reason}, 1_000

    assert :ok =
             PidAdapter.deliver(signal, target: dead_pid, delivery_mode: :async)
  end

  test "dispatch keeps async pid delivery deterministic for dead targets" do
    {:ok, signal} =
      Signal.new(%{
        type: "pid.dispatch.async.dead",
        source: "/test",
        data: %{value: 2}
      })

    dead_pid =
      spawn(fn ->
        receive do
        after
          0 -> :ok
        end
      end)

    ref = Process.monitor(dead_pid)
    assert_receive {:DOWN, ^ref, :process, ^dead_pid, _reason}, 1_000

    assert :ok = Dispatch.dispatch(signal, {:pid, [target: dead_pid, delivery_mode: :async]})
  end

  test "sync delivery still reports dead process errors" do
    {:ok, signal} =
      Signal.new(%{
        type: "pid.adapter.sync.dead",
        source: "/test",
        data: %{value: 3}
      })

    dead_pid =
      spawn(fn ->
        receive do
        after
          0 -> :ok
        end
      end)

    ref = Process.monitor(dead_pid)
    assert_receive {:DOWN, ^ref, :process, ^dead_pid, _reason}, 1_000

    assert {:error, :process_not_alive} =
             PidAdapter.deliver(signal, target: dead_pid, delivery_mode: :sync, timeout: 50)
  end
end
