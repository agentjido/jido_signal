defmodule JidoTest.Signal.Bus.DLQNonBlockingCallbacksTest do
  use ExUnit.Case, async: false

  alias Jido.Signal
  alias Jido.Signal.Bus

  @moduletag :capture_log

  defmodule BlockingDLQAdapter do
    def init do
      test_pid = Application.fetch_env!(:jido_signal, :blocking_dlq_test_pid)

      Agent.start_link(fn ->
        %{
          test_pid: test_pid,
          entries: %{}
        }
      end)
    end

    def put_signal(_signal, _pid), do: :ok
    def get_signal(_signal_id, _pid), do: {:error, :not_found}
    def put_cause(_cause_id, _effect_id, _pid), do: :ok
    def get_effects(_signal_id, _pid), do: {:ok, MapSet.new()}
    def get_cause(_signal_id, _pid), do: {:error, :not_found}
    def put_conversation(_conversation_id, _signal_id, _pid), do: :ok
    def get_conversation(_conversation_id, _pid), do: {:ok, MapSet.new()}
    def put_checkpoint(_subscription_id, _checkpoint, _pid), do: :ok
    def get_checkpoint(_subscription_id, _pid), do: {:error, :not_found}
    def delete_checkpoint(_subscription_id, _pid), do: :ok
    def delete_dlq_entry(_entry_id, _pid), do: :ok

    def put_dlq_entry(subscription_id, signal, reason, metadata, pid) do
      entry = %{
        id: "dlq-#{System.unique_integer([:positive])}",
        subscription_id: subscription_id,
        signal: signal,
        reason: reason,
        metadata: metadata,
        inserted_at: DateTime.utc_now()
      }

      Agent.update(pid, fn state ->
        entries = Map.update(state.entries, subscription_id, [entry], &(&1 ++ [entry]))
        %{state | entries: entries}
      end)

      {:ok, entry.id}
    end

    def get_dlq_entries(subscription_id, pid) do
      {test_pid, entries} =
        Agent.get(pid, fn state ->
          {state.test_pid, Map.get(state.entries, subscription_id, [])}
        end)

      caller = self()
      send(test_pid, {:dlq_entries_called, caller, subscription_id})

      receive do
        {:release_dlq_entries, ^subscription_id} -> {:ok, entries}
      end
    end

    def clear_dlq(subscription_id, pid) do
      test_pid = Agent.get(pid, & &1.test_pid)
      caller = self()
      send(test_pid, {:clear_dlq_called, caller, subscription_id})

      receive do
        {:release_clear_dlq, ^subscription_id} ->
          Agent.update(pid, fn state ->
            %{state | entries: Map.delete(state.entries, subscription_id)}
          end)

          :ok
      end
    end
  end

  setup do
    Application.put_env(:jido_signal, :blocking_dlq_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:jido_signal, :blocking_dlq_test_pid)
    end)

    :ok
  end

  defp build_signal(type) do
    Signal.new!(%{
      type: type,
      source: "/test",
      data: %{value: 42}
    })
  end

  test "dlq_entries does not block unrelated bus calls while adapter work is in progress" do
    bus_name = :"dlq_non_blocking_entries_#{System.unique_integer([:positive])}"
    {:ok, bus_pid} = Bus.start_link(name: bus_name, journal_adapter: BlockingDLQAdapter)
    state = :sys.get_state(bus_pid)
    subscription_id = "sub-#{System.unique_integer([:positive])}"

    {:ok, _entry_id} =
      BlockingDLQAdapter.put_dlq_entry(
        subscription_id,
        build_signal("test.entries"),
        :max_attempts_exceeded,
        %{},
        state.journal_pid
      )

    parent = self()

    spawn(fn ->
      send(parent, {:dlq_result, Bus.dlq_entries(bus_name, subscription_id)})
    end)

    assert_receive {:dlq_entries_called, caller_pid, ^subscription_id}, 1_000

    spawn(fn ->
      send(parent, {:snapshot_result, Bus.snapshot_list(bus_name)})
    end)

    try do
      assert_receive {:snapshot_result, []}, 200
    after
      send(caller_pid, {:release_dlq_entries, subscription_id})
    end

    assert_receive {:dlq_result, {:ok, [_entry]}}, 1_000
  end

  test "clear_dlq does not block unrelated bus calls while adapter work is in progress" do
    bus_name = :"dlq_non_blocking_clear_#{System.unique_integer([:positive])}"
    {:ok, bus_pid} = Bus.start_link(name: bus_name, journal_adapter: BlockingDLQAdapter)
    state = :sys.get_state(bus_pid)
    subscription_id = "sub-#{System.unique_integer([:positive])}"

    {:ok, _entry_id} =
      BlockingDLQAdapter.put_dlq_entry(
        subscription_id,
        build_signal("test.clear"),
        :max_attempts_exceeded,
        %{},
        state.journal_pid
      )

    parent = self()

    spawn(fn ->
      send(parent, {:clear_result, Bus.clear_dlq(bus_name, subscription_id)})
    end)

    assert_receive {:clear_dlq_called, caller_pid, ^subscription_id}, 1_000

    spawn(fn ->
      send(parent, {:snapshot_result, Bus.snapshot_list(bus_name)})
    end)

    try do
      assert_receive {:snapshot_result, []}, 200
    after
      send(caller_pid, {:release_clear_dlq, subscription_id})
    end

    assert_receive {:clear_result, :ok}, 1_000
  end
end
