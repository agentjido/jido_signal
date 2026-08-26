defmodule Jido.Signal.Bus.V3BusTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus

  defmodule FailingStore do
    def init(_opts), do: {:error, :unavailable}
  end

  defmodule ToggleAdapter do
    @behaviour Jido.Signal.Dispatch.Adapter

    @impl true
    def validate_opts(opts) do
      if is_pid(opts[:toggle]) and is_pid(opts[:observer]),
        do: {:ok, opts},
        else: {:error, :invalid_test_options}
    end

    @impl true
    def deliver(signal, opts) do
      send(opts[:observer], {:delivery_attempt, signal})

      if Agent.get(opts[:toggle], & &1) do
        :ok
      else
        {:error, :delivery_failed}
      end
    end
  end

  defmodule OrderAdapter do
    @behaviour Jido.Signal.Dispatch.Adapter

    @impl true
    def validate_opts(opts), do: {:ok, opts}

    @impl true
    def deliver(signal, opts) do
      send(opts[:observer], {:ordered_delivery, opts[:label], signal})
      :ok
    end
  end

  defmodule ObservingStore do
    alias Jido.Signal.Bus.Store.Memory

    def init(opts) do
      observer = Keyword.fetch!(opts, :observer)

      with {:ok, memory} <- Memory.init(Keyword.delete(opts, :observer)) do
        {:ok, %{memory: memory, observer: observer}}
      end
    end

    def append(records, state) do
      send(state.observer, {:stored_records, records})

      with {:ok, memory} <- Memory.append(records, state.memory) do
        {:ok, %{state | memory: memory}}
      end
    end

    def read(opts, state), do: Memory.read(opts, state.memory)
  end

  test "publishes in order and keeps a bounded replay log" do
    bus = start_bus(max_log_size: 2)

    signals = [signal("order.one"), signal("order.two"), signal("order.three")]
    assert {:ok, records} = Bus.publish(bus, signals)
    assert Enum.map(records, & &1.cursor) == [1, 2, 3]

    assert {:ok, replayed} = Bus.replay(bus, "order.**")
    assert Enum.map(replayed, & &1.signal.type) == ["order.two", "order.three"]
    assert Enum.map(replayed, & &1.cursor) == [2, 3]
  end

  test "keeps Router precedence through Bus delivery" do
    bus = start_bus()

    assert {:ok, _id} =
             Bus.subscribe(bus, "ordered.**",
               dispatch: {OrderAdapter, observer: self(), label: :multi}
             )

    assert {:ok, _id} =
             Bus.subscribe(bus, "ordered.*",
               dispatch: {OrderAdapter, observer: self(), label: :single}
             )

    assert {:ok, _id} =
             Bus.subscribe(bus, "ordered.event",
               dispatch: {OrderAdapter, observer: self(), label: :exact}
             )

    event = signal("ordered.event")
    assert {:ok, [_record]} = Bus.publish(bus, [event])

    assert_receive {:ordered_delivery, :exact, ^event}
    assert_receive {:ordered_delivery, :single, ^event}
    assert_receive {:ordered_delivery, :multi, ^event}
  end

  test "writes an explicit Store record version and canonical Signal map" do
    bus = start_bus(store: ObservingStore, store_opts: [observer: self()])
    event = signal("stored.created")

    assert {:ok, [_record]} = Bus.publish(bus, [event])

    assert_receive {:stored_records, [stored]}
    assert stored["format_version"] == 1
    assert stored["cursor"] == 1
    assert stored["signal"] == Signal.to_map(event)
    assert stored["signal"]["jido_schema_version"] == 2
  end

  test "removes a regular subscription after its target exits" do
    bus = start_bus()
    client = spawn(fn -> receive do: (:stop -> :ok) end)
    monitor_ref = Process.monitor(client)
    subscription_id = "short-lived"

    assert {:ok, ^subscription_id} =
             Bus.subscribe(bus, "short.*",
               subscription_id: subscription_id,
               dispatch: {:pid, target: client}
             )

    Process.exit(client, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^client, :killed}

    assert_eventually(fn ->
      case Bus.subscribe(bus, "short.*", subscription_id: subscription_id) do
        {:ok, ^subscription_id} -> true
        {:error, :subscription_already_exists} -> false
      end
    end)
  end

  test "does not skip an unacknowledged record after an out-of-order acknowledgement" do
    bus = start_bus()

    assert {:ok, subscription_id} =
             Bus.subscribe(bus, "durable.*", persistent?: true, start_from: :current)

    first = signal("durable.first")
    second = signal("durable.second")
    assert {:ok, [first_record, second_record]} = Bus.publish(bus, [first, second])
    assert_receive {:signal, ^first}
    assert_receive {:signal, ^second}

    assert :ok = Bus.ack(bus, subscription_id, second_record.id)
    assert {:ok, 0} = Bus.reconnect(bus, subscription_id, self())

    assert_receive {:signal, ^first}
    assert_receive {:signal, ^second}

    assert :ok = Bus.ack(bus, subscription_id, first_record.id)
    assert :ok = Bus.ack(bus, subscription_id, second_record.id)
    assert {:ok, 2} = Bus.reconnect(bus, subscription_id, self())
    refute_receive {:signal, _signal}, 50
  end

  test "retains records while a persistent subscriber is disconnected" do
    bus = start_bus()
    parent = self()
    client = spawn(fn -> relay(parent, :old_client) end)
    monitor_ref = Process.monitor(client)

    assert {:ok, subscription_id} =
             Bus.subscribe(bus, "offline.*",
               persistent?: true,
               start_from: :current,
               dispatch: {:pid, target: client}
             )

    Process.exit(client, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^client, :killed}

    event = signal("offline.created")
    assert {:ok, [_record]} = Bus.publish(bus, [event])

    new_client = spawn(fn -> relay(parent, :new_client) end)
    assert {:ok, 0} = Bus.reconnect(bus, subscription_id, new_client)
    assert_receive {:relayed, :new_client, ^event}
  end

  test "moves a persistent delivery failure to the Bus dead-letter queue" do
    bus = start_bus()
    {:ok, toggle} = start_supervised({Agent, fn -> false end})

    assert {:ok, subscription_id} =
             Bus.subscribe(bus, "failed.*",
               persistent?: true,
               dispatch: {ToggleAdapter, toggle: toggle, observer: self()}
             )

    event = signal("failed.delivery")
    assert {:ok, [_record]} = Bus.publish(bus, [event])
    assert_receive {:delivery_attempt, ^event}

    assert {:ok, [entry]} = Bus.dlq_entries(bus, subscription_id)
    assert entry.signal == event
    assert entry.metadata["attempt_count"] == 1

    Agent.update(toggle, fn _value -> true end)
    assert {:ok, %{succeeded: 1, failed: 0}} = Bus.redrive_dlq(bus, subscription_id)
    assert_receive {:delivery_attempt, ^event}
    assert {:ok, []} = Bus.dlq_entries(bus, subscription_id)
  end

  test "fails startup when the selected store cannot start" do
    Process.flag(:trap_exit, true)
    name = unique_name("failed_store")

    assert {:error, {:store_init_failed, :unavailable}} =
             Bus.start_link(name: name, store: FailingStore)
  end

  test "rejects removed Journal and partition options" do
    Process.flag(:trap_exit, true)

    assert {:error, {:unsupported_option, :journal_adapter}} =
             Bus.start_link(name: unique_name("journal"), journal_adapter: ExampleJournal)

    assert {:error, {:unsupported_option, :partition_count}} =
             Bus.start_link(name: unique_name("partition"), partition_count: 2)
  end

  defp start_bus(opts \\ []) do
    name = unique_name("v3_bus")
    start_supervised!({Bus, Keyword.put(opts, :name, name)})
  end

  defp signal(type), do: Signal.new!(type, %{type: type}, source: "/test")

  defp unique_name(prefix) do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp relay(parent, label) do
    receive do
      {:signal, signal} ->
        send(parent, {:relayed, label, signal})
        relay(parent, label)
    end
  end

  defp assert_eventually(fun, attempts \\ 20)

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
