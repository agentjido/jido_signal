defmodule Jido.Signal.Bus.DurableSubscriptionTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias Jido.Signal.Bus.RecordedSignal

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

  test "validates durable acknowledgement state" do
    bus = start_bus()

    assert {:error, :subscription_not_found} = Bus.ack(bus, "missing", 1)
    assert {:error, :invalid_cursor} = Bus.ack(bus, "missing", -1)

    assert {:ok, "normal"} =
             Bus.subscribe(bus, "normal.*", subscription_id: "normal")

    assert {:error, :subscription_not_durable} = Bus.ack(bus, "normal", 1)

    assert {:ok, "waiting"} = Bus.subscribe(bus, "waiting.*", durable: "waiting")
    assert {:error, :no_record_in_flight} = Bus.ack(bus, "waiting", 1)
  end

  test "validates durable start cursors" do
    bus = start_bus()

    assert {:ok, [_first, _second]} =
             Bus.publish(bus, [signal("cursor.first"), signal("cursor.second")])

    assert {:ok, "cursor-one"} =
             Bus.subscribe(bus, "cursor.*", durable: "cursor-one", start_from: 1)

    assert_receive {:signal, "cursor-one", %RecordedSignal{cursor: 2}}

    assert {:error, {:invalid_option, :start_from}} =
             Bus.subscribe(bus, "cursor.*", durable: "future", start_from: 3)

    assert {:error, {:invalid_option, :start_from}} =
             Bus.subscribe(bus, "cursor.*", durable: "invalid", start_from: :invalid)
  end

  test "returns the existing durable subscription for the same target" do
    bus = start_bus()

    assert {:ok, "same"} = Bus.subscribe(bus, "same.*", durable: "same")
    assert {:ok, "same"} = Bus.subscribe(bus, "same.*", durable: "same")
  end

  test "rejects identity conflicts and invalid subscription options" do
    bus = start_bus()

    assert {:error, {:conflicting_options, [:durable, :subscription_id]}} =
             Bus.subscribe(bus, "**", durable: "one", subscription_id: "two")

    assert {:error, {:requires_option, :start_from, :durable}} =
             Bus.subscribe(bus, "**", start_from: :origin)

    assert {:error, {:invalid_option, :durable}} =
             Bus.subscribe(bus, "**", durable: "")

    assert {:error, {:invalid_option, :subscription_id}} =
             Bus.subscribe(bus, "**", subscription_id: "")

    assert {:ok, "shared"} =
             Bus.subscribe(bus, "normal.*", subscription_id: "shared")

    assert {:error, :subscription_already_exists} =
             Bus.subscribe(bus, "durable.*", durable: "shared")
  end

  test "validates unsubscribe, delete, replay, and target inputs" do
    bus = start_bus()

    assert {:error, :subscription_not_found} = Bus.unsubscribe(bus, "missing")
    assert {:error, :invalid_options} = Bus.unsubscribe(bus, "missing", force: true)
    assert {:error, :subscription_not_found} = Bus.delete_subscription(bus, "missing")
    assert {:error, _reason} = Bus.subscribe(bus, "bad.***")
    assert {:error, :invalid_target} = Bus.subscribe(bus, "**", target: :not_a_pid)

    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, _reason}
    assert {:error, :target_not_alive} = Bus.subscribe(bus, "**", target: dead)

    assert {:error, :invalid_options} = Bus.replay(bus, "**", :invalid)
    assert {:error, {:unsupported_option, :unknown}} = Bus.replay(bus, "**", unknown: true)
    assert {:error, {:invalid_option, :after}} = Bus.replay(bus, "**", after: -1)
    assert {:error, {:invalid_option, :limit}} = Bus.replay(bus, "**", limit: 0)
    assert {:error, _reason} = Bus.replay(bus, "bad.***")
  end

  test "removes an ephemeral subscription without changing other routes" do
    bus = start_bus()
    assert {:ok, "first"} = Bus.subscribe(bus, "kept.*", subscription_id: "first")
    assert {:ok, "second"} = Bus.subscribe(bus, "kept.*", subscription_id: "second")

    assert :ok = Bus.delete_subscription(bus, "first")
    event = signal("kept.event")
    assert {:ok, [_record]} = Bus.publish(bus, [event])
    assert_receive {:signal, ^event}
    refute_receive {:signal, ^event}, 20
  end

  defp start_bus(opts \\ []) do
    name = unique_name("durable_bus")
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
