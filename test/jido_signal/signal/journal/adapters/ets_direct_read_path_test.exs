defmodule Jido.Signal.Journal.Adapters.ETSDirectReadPathTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Journal.Adapters.ETS

  defp signal(type) do
    Signal.new!(%{
      type: type,
      source: "/test",
      data: %{value: type}
    })
  end

  setup do
    {:ok, pid} = ETS.init()

    on_exit(fn ->
      if Process.alive?(pid), do: ETS.cleanup(pid)
    end)

    {:ok, pid: pid}
  end

  test "dlq read path remains responsive when adapter process is suspended", %{pid: pid} do
    subscription_id = "sub-#{System.unique_integer([:positive])}"
    {:ok, _entry_id} = ETS.put_dlq_entry(subscription_id, signal("test.dlq"), :error, %{}, pid)

    :ok = :sys.suspend(pid)

    try do
      parent = self()

      spawn(fn ->
        send(parent, {:entries_result, ETS.get_dlq_entries(subscription_id, pid, limit: 1)})
      end)

      assert_receive {:entries_result, {:ok, entries}}, 200
      assert length(entries) == 1
    after
      :ok = :sys.resume(pid)
    end
  end

  test "get_all_signals supports bounded direct reads when adapter process is suspended", %{
    pid: pid
  } do
    :ok = ETS.put_signal(signal("test.signals.1"), pid)
    :ok = ETS.put_signal(signal("test.signals.2"), pid)
    :ok = ETS.put_signal(signal("test.signals.3"), pid)

    :ok = :sys.suspend(pid)

    try do
      parent = self()

      spawn(fn ->
        send(parent, {:signals_result, ETS.get_all_signals(pid, limit: 2)})
      end)

      assert_receive {:signals_result, signals}, 200
      assert length(signals) == 2
    after
      :ok = :sys.resume(pid)
    end
  end
end
