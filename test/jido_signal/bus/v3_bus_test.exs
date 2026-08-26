defmodule Jido.Signal.Bus.V3BusTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias Jido.Signal.Bus.RecordedSignal

  defmodule FailingStore do
    def init(_opts), do: {:error, :unavailable}
  end

  defmodule ObservingStore do
    @behaviour Jido.Signal.Bus.Store

    alias Jido.Signal.Bus.Store.Memory

    @impl true
    def init(opts) do
      observer = Keyword.fetch!(opts, :observer)

      with {:ok, memory} <- Memory.init(Keyword.delete(opts, :observer)) do
        {:ok, %{memory: memory, observer: observer}}
      end
    end

    @impl true
    def append(records, state) do
      send(state.observer, {:stored_records, records})

      with {:ok, memory} <- Memory.append(records, state.memory) do
        {:ok, %{state | memory: memory}}
      end
    end

    @impl true
    def read(opts, state), do: Memory.read(opts, state.memory)

    @impl true
    def latest_cursor(state), do: Memory.latest_cursor(state.memory)

    @impl true
    def list_subscriptions(state), do: Memory.list_subscriptions(state.memory)

    @impl true
    def put_subscription(subscription, state) do
      with {:ok, memory} <- Memory.put_subscription(subscription, state.memory) do
        {:ok, %{state | memory: memory}}
      end
    end

    @impl true
    def delete_subscription(id, state) do
      with {:ok, memory} <- Memory.delete_subscription(id, state.memory) do
        {:ok, %{state | memory: memory}}
      end
    end
  end

  defmodule SharedStore do
    @behaviour Jido.Signal.Bus.Store

    alias Jido.Signal.Bus.Store.Memory

    @impl true
    def init(opts) do
      case Keyword.fetch(opts, :agent) do
        {:ok, agent} when is_pid(agent) -> {:ok, agent}
        _invalid -> {:error, :missing_agent}
      end
    end

    @impl true
    def append(records, agent), do: update(agent, &Memory.append(records, &1))

    @impl true
    def read(opts, agent), do: Agent.get(agent, &Memory.read(opts, &1))

    @impl true
    def latest_cursor(agent), do: Agent.get(agent, &Memory.latest_cursor/1)

    @impl true
    def list_subscriptions(agent), do: Agent.get(agent, &Memory.list_subscriptions/1)

    @impl true
    def put_subscription(subscription, agent) do
      update(agent, &Memory.put_subscription(subscription, &1))
    end

    @impl true
    def delete_subscription(id, agent) do
      update(agent, &Memory.delete_subscription(id, &1))
    end

    defp update(agent, function) do
      Agent.get_and_update(agent, fn state ->
        case function.(state) do
          {:ok, next_state} -> {{:ok, agent}, next_state}
          {:error, reason} -> {{:error, reason}, state}
        end
      end)
    end
  end

  test "publishes in order and keeps a bounded replay log" do
    bus = start_bus(max_log_size: 2)

    signals = [signal("order.one"), signal("order.two"), signal("order.three")]
    assert {:ok, records} = Bus.publish(bus, signals)
    assert Enum.map(records, & &1.cursor) == [1, 2, 3]

    assert {:ok, replayed} = Bus.replay(bus, "order.**")
    assert Enum.map(replayed, & &1.signal.type) == ["order.two", "order.three"]
    assert Enum.map(replayed, & &1.cursor) == [2, 3]

    assert {:ok, [last]} = Bus.replay(bus, "order.**", after: 2, limit: 1)
    assert last.cursor == 3
  end

  test "keeps Router precedence through Bus delivery" do
    bus = start_bus()
    handler_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:jido, :signal, :bus, :deliver],
        fn _event, _measurements, metadata, target ->
          send(target, {:delivered_to, metadata.subscription_id})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, "multi"} =
             Bus.subscribe(bus, "ordered.**", subscription_id: "multi")

    assert {:ok, "single"} =
             Bus.subscribe(bus, "ordered.*", subscription_id: "single")

    assert {:ok, "exact"} =
             Bus.subscribe(bus, "ordered.event", subscription_id: "exact")

    event = signal("ordered.event")
    assert {:ok, [_record]} = Bus.publish(bus, [event])

    assert_receive {:delivered_to, "exact"}
    assert_receive {:delivered_to, "single"}
    assert_receive {:delivered_to, "multi"}
  end

  test "stores a versioned canonical Signal map before delivery" do
    bus = start_bus(store: ObservingStore, store_opts: [observer: self()])
    assert {:ok, _id} = Bus.subscribe(bus, "stored.*")
    event = signal("stored.created")

    assert {:ok, [_record]} = Bus.publish(bus, [event])

    assert_receive {:stored_records, [stored]}
    assert stored["format_version"] == 1
    assert stored["cursor"] == 1
    assert stored["signal"] == Signal.to_map(event)
    assert stored["signal"]["specversion"] == "1.0"
    assert_receive {:signal, ^event}
  end

  test "removes a normal subscription after its target exits" do
    bus = start_bus()
    client = spawn(fn -> receive do: (:stop -> :ok) end)
    monitor_ref = Process.monitor(client)

    assert {:ok, "short-lived"} =
             Bus.subscribe(bus, "short.*", subscription_id: "short-lived", target: client)

    Process.exit(client, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^client, :killed}

    assert_eventually(fn ->
      Bus.subscribe(bus, "short.*", subscription_id: "short-lived") ==
        {:ok, "short-lived"}
    end)
  end

  test "sends one durable record at a time and advances only its cursor" do
    bus = start_bus()
    assert {:ok, "orders-agent"} = Bus.subscribe(bus, "durable.*", durable: "orders-agent")

    first = signal("durable.first")
    second = signal("durable.second")
    assert {:ok, [first_record, second_record]} = Bus.publish(bus, [first, second])

    assert_receive {:signal, "orders-agent", %RecordedSignal{} = delivered_first}
    assert delivered_first.cursor == first_record.cursor
    assert delivered_first.signal == first
    refute_receive {:signal, "orders-agent", _record}, 50

    assert {:error, {:unexpected_cursor, 1}} = Bus.ack(bus, "orders-agent", 2)
    assert :ok = Bus.ack(bus, "orders-agent", delivered_first.cursor)

    assert_receive {:signal, "orders-agent", %RecordedSignal{} = delivered_second}
    assert delivered_second.cursor == second_record.cursor
    assert delivered_second.signal == second
    assert :ok = Bus.ack(bus, "orders-agent", delivered_second.cursor)
    refute_receive {:signal, "orders-agent", _record}, 50
  end

  test "sends an unacknowledged record again after a target exits" do
    bus = start_bus()
    parent = self()
    client = spawn(fn -> relay_durable(parent) end)
    client_ref = Process.monitor(client)

    assert {:ok, "offline-agent"} =
             Bus.subscribe(bus, "offline.*", durable: "offline-agent", target: client)

    event = signal("offline.created")
    assert {:ok, [published]} = Bus.publish(bus, [event])
    assert_receive {:relayed, "offline-agent", %RecordedSignal{} = first_delivery}
    assert first_delivery.cursor == published.cursor

    Process.exit(client, :kill)
    assert_receive {:DOWN, ^client_ref, :process, ^client, :killed}

    assert_eventually(fn ->
      Bus.subscribe(bus, "offline.*", durable: "offline-agent") == {:ok, "offline-agent"}
    end)

    assert_receive {:signal, "offline-agent", %RecordedSignal{} = repeated}
    assert repeated.cursor == first_delivery.cursor
    assert repeated.signal == event
  end

  test "keeps records published while a durable subscription is detached" do
    bus = start_bus()

    assert {:ok, "detached-agent"} =
             Bus.subscribe(bus, "detached.*", durable: "detached-agent")

    assert :ok = Bus.unsubscribe(bus, "detached-agent")
    event = signal("detached.created")
    assert {:ok, [published]} = Bus.publish(bus, [event])
    refute_receive {:signal, "detached-agent", _record}, 50

    assert {:ok, "detached-agent"} =
             Bus.subscribe(bus, "detached.*", durable: "detached-agent")

    assert_receive {:signal, "detached-agent", %RecordedSignal{} = delivered}
    assert delivered.cursor == published.cursor
    assert delivered.signal == event
  end

  test "rejects acknowledgement from a process that does not own the subscription" do
    bus = start_bus()
    parent = self()
    client = spawn(fn -> relay_durable(parent) end)

    assert {:ok, "owned-agent"} =
             Bus.subscribe(bus, "owned.*", durable: "owned-agent", target: client)

    assert {:ok, [published]} = Bus.publish(bus, [signal("owned.created")])
    assert_receive {:relayed, "owned-agent", %RecordedSignal{cursor: cursor}}
    assert cursor == published.cursor
    assert {:error, :not_subscription_owner} = Bus.ack(bus, "owned-agent", cursor)
  end

  test "fails publish without delivery when a durable cursor fills the Store" do
    bus = start_bus(max_log_size: 2)

    assert {:ok, "pressure-agent"} =
             Bus.subscribe(bus, "pressure.*", durable: "pressure-agent", start_from: :origin)

    assert {:ok, _ephemeral} = Bus.subscribe(bus, "pressure.*")
    first = signal("pressure.first")
    second = signal("pressure.second")
    assert {:ok, [_first, _second]} = Bus.publish(bus, [first, second])

    assert_receive {:signal, "pressure-agent", %RecordedSignal{cursor: 1}}
    assert_receive {:signal, ^first}
    assert_receive {:signal, ^second}

    third = signal("pressure.third")

    assert {:error, {:store_error, :append, {:store_full, ["pressure-agent"]}}} =
             Bus.publish(bus, [third])

    refute_receive {:signal, ^third}, 50
    assert {:ok, replayed} = Bus.replay(bus, "pressure.*")
    assert Enum.map(replayed, & &1.cursor) == [1, 2]
  end

  test "loads durable definitions and unacknowledged records from a custom Store" do
    {:ok, memory} = Jido.Signal.Bus.Store.Memory.init([])
    store_agent = start_supervised!({Agent, fn -> memory end})
    dynamic_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    name = unique_name("shared_store")
    bus_opts = [name: name, store: SharedStore, store_opts: [agent: store_agent]]

    assert {:ok, bus} = DynamicSupervisor.start_child(dynamic_supervisor, {Bus, bus_opts})

    assert {:ok, "restart-agent"} =
             Bus.subscribe(bus, "restart.*", durable: "restart-agent")

    event = signal("restart.created")
    assert {:ok, [published]} = Bus.publish(bus, [event])
    assert_receive {:signal, "restart-agent", %RecordedSignal{cursor: cursor}}
    assert cursor == published.cursor

    assert :ok = DynamicSupervisor.terminate_child(dynamic_supervisor, bus)

    assert {:ok, restarted_bus} =
             DynamicSupervisor.start_child(dynamic_supervisor, {Bus, bus_opts})

    assert {:ok, "restart-agent"} =
             Bus.subscribe(restarted_bus, "restart.*", durable: "restart-agent")

    assert_receive {:signal, "restart-agent", %RecordedSignal{} = repeated}
    assert repeated.cursor == published.cursor
    assert repeated.signal == event
  end

  test "allows only one active target for a durable subscription" do
    bus = start_bus()
    other = spawn(fn -> receive do: (:stop -> :ok) end)

    assert {:ok, "single-owner"} = Bus.subscribe(bus, "owner.*", durable: "single-owner")

    assert {:error, :subscription_in_use} =
             Bus.subscribe(bus, "owner.*", durable: "single-owner", target: other)

    assert {:error, :durable_subscription_conflict} =
             Bus.subscribe(bus, "other.*", durable: "single-owner", target: other)
  end

  test "permanently deletes a durable subscription" do
    bus = start_bus()
    assert {:ok, "old-agent"} = Bus.subscribe(bus, "old.*", durable: "old-agent")
    assert :ok = Bus.delete_subscription(bus, "old-agent")

    assert {:ok, "old-agent"} =
             Bus.subscribe(bus, "new.*", durable: "old-agent", start_from: :origin)
  end

  test "fails startup when the selected store cannot start" do
    Process.flag(:trap_exit, true)
    name = unique_name("failed_store")

    assert {:error, {:store_init_failed, :unavailable}} =
             Bus.start_link(name: name, store: FailingStore)
  end

  test "rejects removed Journal, partition, and middleware options" do
    Process.flag(:trap_exit, true)

    assert {:error, {:unsupported_option, :journal_adapter}} =
             Bus.start_link(name: unique_name("journal"), journal_adapter: ExampleJournal)

    assert {:error, {:unsupported_option, :partition_count}} =
             Bus.start_link(name: unique_name("partition"), partition_count: 2)

    assert {:error, {:unsupported_option, :middleware}} =
             Bus.start_link(name: unique_name("middleware"), middleware: [])
  end

  test "rejects the removed dispatch and persistent subscription options" do
    bus = start_bus()

    assert {:error, {:unsupported_option, :dispatch}} =
             Bus.subscribe(bus, "old.*", dispatch: {:pid, target: self()})

    assert {:error, {:unsupported_option, :persistent?}} =
             Bus.subscribe(bus, "old.*", persistent?: true)
  end

  defp start_bus(opts \\ []) do
    name = unique_name("v3_bus")
    start_supervised!({Bus, Keyword.put(opts, :name, name)})
  end

  defp signal(type), do: Signal.new!(type, %{type: type}, source: "/test")

  defp unique_name(prefix) do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp relay_durable(parent) do
    receive do
      {:signal, durable_id, record} ->
        send(parent, {:relayed, durable_id, record})
        relay_durable(parent)
    end
  end

  defp assert_eventually(fun, attempts \\ 40)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end
