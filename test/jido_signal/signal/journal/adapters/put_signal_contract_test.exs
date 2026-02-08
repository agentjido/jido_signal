defmodule Jido.Signal.Journal.Adapters.PutSignalContractTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Journal.Adapters.ETS
  alias Jido.Signal.Journal.Adapters.InMemory

  defp signal(type) do
    Signal.new!(%{
      type: type,
      source: "/test",
      data: %{value: type}
    })
  end

  test "ETS put_signal/2 returns explicit error tuple when adapter process is unavailable" do
    {:ok, pid} = ETS.init()
    :ok = GenServer.stop(pid, :normal)

    assert {:error, _reason} = ETS.put_signal(signal("test.ets.contract"), pid)
  end

  test "InMemory put_signal/2 returns explicit error tuple when adapter process is unavailable" do
    {:ok, pid} = InMemory.init()
    :ok = GenServer.stop(pid, :normal)

    assert {:error, _reason} = InMemory.put_signal(signal("test.in_memory.contract"), pid)
  end
end
