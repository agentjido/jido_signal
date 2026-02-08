defmodule Jido.Signal.Bus.NonBlockingCallbacksTest do
  use ExUnit.Case, async: false

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias Jido.Signal.Bus.Middleware
  alias Jido.Signal.Bus.Partition
  alias Jido.Signal.Dispatch

  @moduletag :capture_log

  defmodule BlockingDispatchAdapter do
    @behaviour Dispatch.Adapter

    @impl true
    def validate_opts(opts), do: {:ok, opts}

    @impl true
    def deliver(signal, opts) do
      if Map.get(signal.data, :block?, false) do
        test_pid = Keyword.fetch!(opts, :test_pid)
        signal_id = signal.id
        send(test_pid, {:dispatch_started, self(), signal_id})

        receive do
          {:release_dispatch, ^signal_id} -> :ok
        end
      else
        :ok
      end
    end
  end

  defmodule BlockingPublishMiddleware do
    @behaviour Middleware

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def before_publish(signals, _context, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:before_publish_started, self()})

      receive do
        :release_before_publish ->
          {:cont, signals, opts}
      end
    end
  end

  defmodule BlockingDispatchMiddleware do
    @behaviour Middleware

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def before_dispatch(signal, _subscriber, _context, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      signal_id = signal.id
      send(test_pid, {:before_dispatch_started, self(), signal_id})

      receive do
        {:release_before_dispatch, ^signal_id} ->
          {:cont, signal, opts}
      end
    end
  end

  defmodule BlockingCheckpointAdapter do
    def init do
      test_pid = Application.fetch_env!(:jido_signal, :blocking_checkpoint_test_pid)

      Agent.start_link(fn ->
        %{
          test_pid: test_pid,
          checkpoints: %{}
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
    def delete_checkpoint(_subscription_id, _pid), do: :ok
    def put_dlq_entry(_subscription_id, _signal, _reason, _metadata, _pid), do: {:ok, "ignored"}
    def get_dlq_entries(_subscription_id, _pid), do: {:ok, []}
    def delete_dlq_entry(_entry_id, _pid), do: :ok
    def clear_dlq(_subscription_id, _pid), do: :ok

    def put_checkpoint(subscription_id, checkpoint, pid) do
      test_pid = Agent.get(pid, & &1.test_pid)
      caller = self()
      send(test_pid, {:checkpoint_put_started, caller, subscription_id, checkpoint})

      receive do
        {:release_checkpoint_put, ^subscription_id} ->
          Agent.update(pid, fn state ->
            %{state | checkpoints: Map.put(state.checkpoints, subscription_id, checkpoint)}
          end)

          :ok
      end
    end

    def get_checkpoint(subscription_id, pid) do
      case Agent.get(pid, fn state -> Map.get(state.checkpoints, subscription_id) end) do
        nil -> {:error, :not_found}
        checkpoint -> {:ok, checkpoint}
      end
    end
  end

  setup do
    Application.put_env(:jido_signal, :blocking_checkpoint_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:jido_signal, :blocking_checkpoint_test_pid)
    end)

    :ok
  end

  test "publish callback stays responsive while before_publish middleware is blocked" do
    bus_name = :"non_blocking_publish_callback_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Bus,
       name: bus_name,
       middleware_timeout_ms: 5_000,
       middleware: [{BlockingPublishMiddleware, test_pid: self()}]}
    )

    signal = Signal.new!(type: "test.publish.callback", source: "/test", data: %{value: 1})
    parent = self()

    spawn(fn ->
      send(parent, {:publish_result, Bus.publish(bus_name, [signal])})
    end)

    assert_receive {:before_publish_started, middleware_pid}, 1_000

    spawn(fn ->
      send(parent, {:snapshot_result, Bus.snapshot_list(bus_name)})
    end)

    try do
      assert_receive {:snapshot_result, []}, 200
    after
      send(middleware_pid, :release_before_publish)
    end

    assert_receive {:publish_result, {:ok, [_recorded_signal]}}, 1_000
  end

  test "partition callback stays responsive while dispatch middleware is blocked" do
    bus_name = :"non_blocking_partition_callback_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Bus,
       name: bus_name,
       partition_count: 2,
       middleware_timeout_ms: 5_000,
       middleware: [{BlockingDispatchMiddleware, test_pid: self()}]}
    )

    {:ok, subscription_id} = Bus.subscribe(bus_name, "test.partition.callback")

    signal =
      Signal.new!(type: "test.partition.callback", source: "/test", data: %{value: "blocked"})

    parent = self()

    spawn(fn ->
      send(parent, {:publish_result, Bus.publish(bus_name, [signal])})
    end)

    assert_receive {:before_dispatch_started, middleware_pid, signal_id}, 1_000

    partition_id = Partition.partition_for(subscription_id, 2)
    partition = Partition.via_tuple(bus_name, partition_id)

    spawn(fn ->
      result =
        try do
          {:ok, GenServer.call(partition, :get_subscriptions, 200)}
        catch
          :exit, reason -> {:error, reason}
        end

      send(parent, {:partition_query_result, result})
    end)

    try do
      assert_receive {:partition_query_result, {:ok, {:ok, subscriptions}}}, 200
      assert Map.has_key?(subscriptions, subscription_id)
    after
      send(middleware_pid, {:release_before_dispatch, signal_id})
    end

    assert_receive {:publish_result, {:ok, [_recorded_signal]}}, 1_000
  end

  test "publish returns before a persistent subscription finishes blocking downstream dispatch" do
    bus_name = :"non_blocking_publish_#{System.unique_integer([:positive])}"
    start_supervised!({Bus, name: bus_name})

    {:ok, _subscription_id} =
      Bus.subscribe(bus_name, "test.blocking",
        persistent?: true,
        max_in_flight: 1,
        max_pending: 10,
        dispatch: {BlockingDispatchAdapter, [test_pid: self()]}
      )

    signal = Signal.new!(type: "test.blocking", source: "/test", data: %{value: 1, block?: true})
    signal_id = signal.id
    parent = self()

    spawn(fn ->
      send(parent, {:publish_result, Bus.publish(bus_name, [signal])})
    end)

    assert_receive {:dispatch_started, dispatch_pid, ^signal_id}, 1_000

    try do
      assert_receive {:publish_result, {:ok, [_recorded_signal]}}, 200
    after
      send(dispatch_pid, {:release_dispatch, signal_id})
    end
  end

  test "publish returns promptly when persistent subscription process is unresponsive" do
    bus_name = :"non_blocking_persistent_accept_#{System.unique_integer([:positive])}"
    start_supervised!({Bus, name: bus_name})

    {:ok, subscription_id} =
      Bus.subscribe(bus_name, "test.unresponsive",
        persistent?: true,
        max_in_flight: 1,
        max_pending: 1,
        dispatch: {:pid, target: self(), delivery_mode: :async}
      )

    {:ok, bus_pid} = Bus.whereis(bus_name)
    bus_state = :sys.get_state(bus_pid)
    %{persistence_pid: persistence_pid} = Map.fetch!(bus_state.subscriptions, subscription_id)

    :ok = :sys.suspend(persistence_pid)

    signal = Signal.new!(type: "test.unresponsive", source: "/test", data: %{value: 1})
    task = Task.async(fn -> Bus.publish(bus_name, [signal]) end)

    try do
      assert {:ok, _result} = Task.yield(task, 200)
    after
      Task.shutdown(task, :brutal_kill)
      :ok = :sys.resume(persistence_pid)
    end
  end

  test "ack returns before processing pending blocking dispatch work" do
    bus_name = :"non_blocking_ack_#{System.unique_integer([:positive])}"
    start_supervised!({Bus, name: bus_name})

    {:ok, subscription_id} =
      Bus.subscribe(bus_name, "test.ack",
        persistent?: true,
        max_in_flight: 1,
        max_pending: 10,
        dispatch: {BlockingDispatchAdapter, [test_pid: self()]}
      )

    first_signal = Signal.new!(type: "test.ack", source: "/test", data: %{value: 1})
    {:ok, [first_recorded]} = Bus.publish(bus_name, [first_signal])

    second_signal =
      Signal.new!(type: "test.ack", source: "/test", data: %{value: 2, block?: true})

    second_signal_id = second_signal.id
    {:ok, [_second_recorded]} = Bus.publish(bus_name, [second_signal])

    parent = self()

    spawn(fn ->
      send(parent, {:ack_result, Bus.ack(bus_name, subscription_id, first_recorded.id)})
    end)

    assert_receive {:dispatch_started, dispatch_pid, ^second_signal_id}, 1_000

    try do
      assert_receive {:ack_result, :ok}, 200
    after
      send(dispatch_pid, {:release_dispatch, second_signal_id})
    end
  end

  test "ack callback stays responsive while checkpoint persistence is blocked" do
    bus_name = :"non_blocking_ack_checkpoint_#{System.unique_integer([:positive])}"
    {:ok, _bus_pid} = Bus.start_link(name: bus_name, journal_adapter: BlockingCheckpointAdapter)

    {:ok, subscription_id} =
      Bus.subscribe(bus_name, "test.ack.checkpoint",
        persistent?: true,
        dispatch: {:pid, target: self(), delivery_mode: :async}
      )

    signal = Signal.new!(type: "test.ack.checkpoint", source: "/test", data: %{value: 1})
    {:ok, [recorded]} = Bus.publish(bus_name, [signal])
    assert_receive {:signal, %Signal{type: "test.ack.checkpoint"}}, 1_000

    parent = self()

    spawn(fn ->
      send(parent, {:ack_result, Bus.ack(bus_name, subscription_id, recorded.id)})
    end)

    assert_receive {:checkpoint_put_started, checkpoint_worker, checkpoint_key, _checkpoint},
                   1_000

    spawn(fn ->
      send(parent, {:snapshot_result, Bus.snapshot_list(bus_name)})
    end)

    try do
      assert_receive {:snapshot_result, []}, 200
    after
      send(checkpoint_worker, {:release_checkpoint_put, checkpoint_key})
    end

    assert_receive {:ack_result, :ok}, 1_000
  end
end
