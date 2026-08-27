defmodule Jido.Signal.BusTest do
  use JidoSignalTest.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus

  defmodule FailingStore do
    def init(_opts), do: {:error, :unavailable}
  end

  defmodule InvalidInitStore do
    def init(_opts), do: :invalid
  end

  defmodule RaisingInitStore do
    def init(_opts), do: raise("store failed")
  end

  defmodule StartupStore do
    @behaviour Jido.Signal.Bus.Store

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def append(_records, state), do: {:ok, state}

    @impl true
    def read(_opts, _state), do: {:ok, []}

    @impl true
    def latest_cursor(state), do: Map.get(state, :latest_cursor, {:ok, 0})

    @impl true
    def list_subscriptions(state), do: Map.get(state, :subscriptions, {:ok, []})

    @impl true
    def put_subscription(_subscription, state), do: {:ok, state}

    @impl true
    def delete_subscription(_id, state), do: {:ok, state}
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

    assert {:ok, "short-lived"} =
             Bus.subscribe(bus, "short.*", subscription_id: "short-lived", target: client)

    terminate_and_wait(bus, client)

    assert {:ok, "short-lived"} =
             Bus.subscribe(bus, "short.*", subscription_id: "short-lived")
  end

  test "fails startup when the selected Store cannot start" do
    Process.flag(:trap_exit, true)
    name = unique_name("failed_store")

    assert {:error, {:store_init_failed, :unavailable}} =
             Bus.start_link(name: name, store: FailingStore)
  end

  test "rejects invalid and failed Store initialization" do
    Process.flag(:trap_exit, true)

    assert {:error, {:store_init_failed, {:invalid_return, :invalid}}} =
             Bus.start_link(name: unique_name("invalid_store"), store: InvalidInitStore)

    assert {:error, {:store_init_failed, {:exception, %RuntimeError{message: "store failed"}}}} =
             Bus.start_link(name: unique_name("raising_store"), store: RaisingInitStore)
  end

  test "rejects invalid persisted Store state" do
    Process.flag(:trap_exit, true)

    assert {:error, {:store_init_failed, :list_subscriptions, {:invalid_return, :invalid}}} =
             Bus.start_link(
               name: unique_name("invalid_list_return"),
               store: StartupStore,
               store_opts: [subscriptions: :invalid]
             )

    assert {:error, :invalid_store_subscriptions} =
             Bus.start_link(
               name: unique_name("invalid_subscriptions"),
               store: StartupStore,
               store_opts: [subscriptions: {:ok, :invalid}]
             )

    assert {:error, :invalid_store_cursor} =
             Bus.start_link(
               name: unique_name("invalid_cursor"),
               store: StartupStore,
               store_opts: [latest_cursor: {:ok, :invalid}]
             )

    definition = %{
      "format_version" => 1,
      "id" => "ahead",
      "path" => "stored.*",
      "cursor" => 1,
      "created_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    assert {:error, :invalid_store_subscription_cursor} =
             Bus.start_link(
               name: unique_name("ahead_cursor"),
               store: StartupStore,
               store_opts: [subscriptions: {:ok, [definition]}]
             )
  end

  test "rejects unknown start options through the Zoi schema" do
    assert {:error, {:invalid_options, message}} =
             Bus.start_link(name: unique_name("invalid_options"), unexpected: true)

    assert message =~ "unrecognized key: unexpected"

    assert_raise ArgumentError, ~r/unrecognized key: unexpected/, fn ->
      Bus.child_spec(name: unique_name("invalid_child_spec"), unexpected: true)
    end
  end

  test "validates all startup boundaries" do
    for opts <- [
          [],
          [name: ""],
          [name: nil],
          [name: :bus, registry: nil],
          [name: :bus, store: nil],
          [name: :bus, max_log_size: 0],
          [name: :bus, store_opts: :invalid]
        ] do
      assert {:error, {:invalid_options, message}} = Bus.start_link(opts)
      assert is_binary(message)
    end
  end

  test "supports PID and explicit Registry lookup" do
    registry = __MODULE__.CustomRegistry
    start_supervised!({Registry, keys: :unique, name: registry})

    {:ok, bus} = Bus.start_link(name: :custom_bus, registry: registry)

    assert Bus.via_tuple({:custom_bus, registry}) ==
             {:via, Registry, {registry, "custom_bus"}}

    assert {:ok, ^bus} = Bus.whereis(bus)
    assert {:ok, ^bus} = Bus.whereis({:custom_bus, registry})

    assert {:ok, _id} = Bus.subscribe({:custom_bus, registry}, "custom.*")
    event = signal("custom.created")
    assert {:ok, [_record]} = Bus.publish({:custom_bus, registry}, [event])
    assert_receive {:signal, ^event}

    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, _reason}
    assert {:error, :not_found} = Bus.whereis(dead)
    assert {:error, :not_found} = Bus.whereis(:missing, registry: __MODULE__.MissingRegistry)
  end

  test "handles empty, invalid, and missing publish targets" do
    assert {:ok, []} = Bus.publish(:not_started, [])
    assert {:error, :invalid_signals} = Bus.publish(:not_started, :invalid)
    assert {:error, :not_found} = Bus.publish(:not_started, [signal("missing.event")])
    assert {:error, :invalid_options} = Bus.subscribe(:not_started, "**", :invalid)
  end

  test "rejects removed dispatch and persistent subscription options" do
    bus = start_bus()

    assert {:error, {:unsupported_option, :dispatch}} =
             Bus.subscribe(bus, "old.*", dispatch: {:pid, target: self()})

    assert {:error, {:unsupported_option, :persistent?}} =
             Bus.subscribe(bus, "old.*", persistent?: true)
  end

  defp start_bus(opts \\ []) do
    name = unique_name("bus")
    start_supervised!({Bus, Keyword.put(opts, :name, name)})
  end
end
