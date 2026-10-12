defmodule Jido.Signal.Bus.SelectorTest do
  use JidoSignalTest.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias Jido.Signal.Bus.Selector
  alias Jido.Signal.Router

  def handle_delivery(_event, _measurements, metadata, {bus, observer}) do
    if self() == bus, do: send(observer, {:delivered, metadata.subscription_id})
  end

  test "combines exact and wildcard types with subject selection for isolated targets" do
    for path <- ["message.added", "message.*", "message.**", "**.added"] do
      bus = start_bus()
      first_target = start_target(:first)
      second_target = start_target(:second)

      assert {:ok, _} =
               Bus.subscribe(bus, path,
                 target: first_target,
                 selector: [{[:subject], "room-1"}]
               )

      assert {:ok, _} =
               Bus.subscribe(bus, path,
                 target: second_target,
                 selector: [{[:subject], "room-2"}]
               )

      assert {:ok, _} = Bus.subscribe(bus, path)

      first = subject_signal("message.added", "room-1")
      second = subject_signal("message.added", "room-2")
      last = subject_signal("message.added", "room-1")
      missing = signal("message.added")
      unrelated = subject_signal("sensor.updated", "room-1")

      assert {:ok, records} = Bus.publish(bus, [first, second, missing, unrelated, last])

      assert Enum.map(records, & &1.signal.id) ==
               Enum.map([first, second, missing, unrelated, last], & &1.id)

      assert_receive {:observed, :first, first_received}
      assert first_received == first
      assert_receive {:observed, :first, last_received}
      assert last_received == last
      assert_receive {:observed, :second, second_received}
      assert second_received == second
      barrier(first_target)
      barrier(second_target)
      refute_received {:observed, _, _}

      for event <- [first, second, missing, last] do
        assert_received {:signal, received}
        assert received == event
      end

      refute_received {:signal, _}
    end
  end

  test "all data clauses must match and preserve exact key and value types" do
    bus = start_bus()

    assert {:ok, _} =
             Bus.subscribe(bus, "sensor.*",
               selector: [
                 {[:source], "/test"},
                 {[:data, "reading", :status], "critical"},
                 {[:data, "reading", :value], 42.0},
                 {[:data, "reading", :active], true}
               ]
             )

    matching =
      signal("sensor.updated", %{"reading" => %{status: "critical", value: 42.0, active: true}})

    wrong_status =
      signal("sensor.updated", %{"reading" => %{status: "normal", value: 42.0, active: true}})

    integer =
      signal("sensor.updated", %{"reading" => %{status: "critical", value: 42, active: true}})

    string_key =
      signal("sensor.updated", %{
        "reading" => %{"status" => "critical", "value" => 42.0, "active" => true}
      })

    atom_key =
      signal("sensor.updated", %{reading: %{status: "critical", value: 42.0, active: true}})

    missing = signal("sensor.updated", %{"reading" => %{status: "critical", value: 42.0}})

    inactive =
      signal("sensor.updated", %{"reading" => %{status: "critical", value: 42.0, active: false}})

    wrong_source = %{matching | source: "/other"}
    wrong_type = %{matching | type: "inventory.updated"}

    assert {:ok, _} =
             Bus.publish(bus, [
               wrong_status,
               integer,
               string_key,
               atom_key,
               missing,
               inactive,
               wrong_source,
               wrong_type,
               matching
             ])

    assert_received {:signal, ^matching}
    refute_received {:signal, _}
  end

  test "missing fields and non-map traversal do not match present nil or false" do
    bus = start_bus()
    assert {:ok, _} = Bus.subscribe(bus, "**", selector: [{[:data, "value"], nil}])
    present = signal("sensor.updated", %{"value" => nil})

    for data <- [%{}, %{"value" => false}, %{"other" => nil}, nil, false, [], [{"value", nil}]] do
      assert {:ok, _} = Bus.publish(bus, [signal("sensor.updated", data)])
      refute_received {:signal, _}
    end

    assert {:ok, _} = Bus.publish(bus, [present])
    assert_received {:signal, ^present}

    assert {:ok, _} = Bus.subscribe(bus, "**", selector: [{[:data, "value", "nested"], nil}])
    assert {:ok, _} = Bus.publish(bus, [signal("sensor.updated", %{"value" => "not-a-map"})])
    refute_received {:signal, _}

    assert {:ok, _} = Bus.subscribe(bus, "**", selector: [{[:data], false}])
    scalar = signal("sensor.updated", false)
    assert {:ok, _} = Bus.publish(bus, [scalar])
    assert_received {:signal, ^scalar}
    refute_received {:signal, _}
  end

  test "selects envelope fields and extension map keys without changing the Signal" do
    bus = start_bus()

    event =
      Signal.new!("sensor.updated", %{},
        source: "/sensors",
        subject: "sensor-1",
        extensions: %{"region" => "west"}
      )

    selector =
      for field <- [
            :id,
            :source,
            :type,
            :specversion,
            :subject,
            :time,
            :datacontenttype,
            :dataschema
          ] do
        {[field], Map.fetch!(event, field)}
      end

    assert {:ok, _} =
             Bus.subscribe(bus, "sensor.*",
               selector: selector ++ [{[:extensions, "region"], "west"}]
             )

    assert {:ok, _} =
             Bus.publish(bus, [%{event | extensions: %{}}, %{event | subject: "sensor-2"}, event])

    assert_received {:signal, ^event}
    refute_received {:signal, _}
  end

  test "rejects invalid and unbounded selectors without executing application code or adding state" do
    bus = start_bus()
    caller = self()

    callback = fn _ ->
      send(caller, :called)
      true
    end

    invalid = [
      nil,
      [],
      false,
      %{},
      callback,
      {__MODULE__, :predicate, []},
      [{[:subject], "room-1"} | :improper],
      [{[:data | :improper], "value"}],
      [{[], "value"}],
      [{["subject"], "value"}],
      [{[:unknown], "value"}],
      [{[:subject, :nested], "value"}],
      [{[:extensions], "value"}],
      [{[:data, 1], "value"}],
      [{[:data, String.duplicate("k", 257)], "value"}],
      [{[:data], String.duplicate("v", 1_025)}],
      [{[:data], :atom}],
      [{[:data], %{}}],
      [{[:data], []}],
      [{[:data], self()}],
      [{[:data], make_ref()}],
      [{[:data], callback}],
      [{[:data], 9_223_372_036_854_775_808}],
      [{[:data], -9_223_372_036_854_775_809}],
      [{List.duplicate(:data, 9), "value"}],
      List.duplicate({[:subject], "value"}, 17),
      [[:subject]],
      [{[:subject], "value", :extra}]
    ]

    for selector <- invalid do
      assert {:error, {:invalid_selector, message}} = Bus.subscribe(bus, "**", selector: selector)
      assert is_binary(message)
      state = :sys.get_state(bus)
      assert state.subscriptions == %{}
      assert state.monitors == %{}
      assert Router.empty?(state.router)
    end

    refute_received :called
    event = signal("sensor.updated")
    assert {:ok, _} = Bus.publish(bus, [event])
    refute_received {:signal, _}
    assert {:ok, _} = Bus.subscribe(bus, "**")
    assert {:ok, _} = Bus.publish(bus, [event])
    assert_received {:signal, ^event}
  end

  test "accepts selectors at the documented bounds" do
    value = String.duplicate("v", 1_024)
    key = String.duplicate("k", 256)
    path = [:data | List.duplicate(key, 7)]
    data = Enum.reduce(1..7, value, fn _, nested -> %{key => nested} end)
    bus = start_bus()
    assert {:ok, _} = Bus.subscribe(bus, "**", selector: List.duplicate({path, value}, 16))
    event = signal("sensor.updated", data)
    assert {:ok, _} = Bus.publish(bus, [event])
    assert_received {:signal, ^event}

    for value <- [-9_223_372_036_854_775_808, 9_223_372_036_854_775_807] do
      assert {:ok, _} = Bus.subscribe(bus, "**", selector: [{[:data], value}])
      event = signal("sensor.updated", value)
      assert {:ok, _} = Bus.publish(bus, [event])
      assert_received {:signal, ^event}
    end
  end

  test "selector with durable subscriptions is rejected before creating or changing durable state" do
    bus = start_bus()
    selector = [{[:subject], "room-1"}]

    for selector <- [selector, nil, []] do
      assert {:error, {:conflicting_options, [:selector, :durable]}} =
               Bus.subscribe(bus, "**", durable: "new", start_from: :origin, selector: selector)
    end

    assert :sys.get_state(bus).subscriptions == %{}
    assert {:ok, "existing"} = Bus.subscribe(bus, "**", durable: "existing")
    assert :ok = Bus.unsubscribe(bus, "existing")
    before = :sys.get_state(bus)

    assert {:error, {:conflicting_options, [:selector, :durable]}} =
             Bus.subscribe(bus, "**", durable: "existing", selector: selector)

    assert :sys.get_state(bus) == before
    assert {:ok, "existing"} = Bus.subscribe(bus, "**", durable: "existing")
    event = subject_signal("message.added", "room-2")
    assert {:ok, [record]} = Bus.publish(bus, [event])
    assert_received {:signal, "existing", ^record}
    assert :ok = Bus.ack(bus, "existing", record.cursor)
    assert {:error, {:unsupported_option, :selector}} = Bus.replay(bus, "**", selector: selector)
    assert {:ok, [^record]} = Bus.replay(bus)
  end

  test "selected routes keep Router precedence and registration order" do
    bus = start_bus()
    event = subject_signal("sensor.updated", "sensor-1")
    selector = [{[:subject], "sensor-1"}]
    handler = unique_name("selector_order")

    :ok =
      :telemetry.attach(
        handler,
        [:jido, :signal, :bus, :deliver],
        &__MODULE__.handle_delivery/4,
        {bus, self()}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    for {id, path, opts} <- [
          {"broad", "**", [selector: selector]},
          {"wildcard", "sensor.*", [selector: selector]},
          {"first", "sensor.updated", [selector: selector]},
          {"skipped", "sensor.updated", [selector: [{[:subject], "sensor-2"}]]},
          {"default", "sensor.updated", []},
          {"last", "sensor.updated", [selector: selector]}
        ] do
      assert {:ok, ^id} = Bus.subscribe(bus, path, [subscription_id: id] ++ opts)
    end

    assert {:ok, ["first", "default", "last", "wildcard", "broad"]} =
             Router.route(:sys.get_state(bus).router, event)

    assert {:ok, _} = Bus.publish(bus, [event])

    for expected <- ["first", "default", "last", "wildcard", "broad"] do
      assert_received {:delivered, received}
      assert received == expected
    end

    refute_received {:delivered, _}
    for _ <- 1..5, do: assert_received({:signal, ^event})
    refute_received {:signal, _}
  end

  test "unsubscribe and delete remove selectors and allow the same ID with a different selector" do
    for removal <- [:unsubscribe, :delete_subscription],
        path <- ["sensor.updated", "sensor.*", "sensor.**", "**.updated"] do
      bus = start_bus()
      first = subject_signal("sensor.updated", "sensor-1")
      second = subject_signal("sensor.updated", "sensor-2")

      assert {:ok, "removed"} =
               Bus.subscribe(bus, path,
                 subscription_id: "removed",
                 selector: [{[:subject], "sensor-1"}]
               )

      assert {:ok, "kept"} =
               Bus.subscribe(bus, path,
                 subscription_id: "kept",
                 selector: [{[:subject], "sensor-2"}]
               )

      assert :ok = apply(Bus, removal, [bus, "removed"])
      state = :sys.get_state(bus)
      refute Map.has_key?(state.subscriptions, "removed")
      assert map_size(state.monitors) == 1
      assert {:error, _} = Router.route(state.router, first)
      assert {:ok, ["kept"]} = Router.route(state.router, second)

      assert {:ok, "removed"} =
               Bus.subscribe(bus, path,
                 subscription_id: "removed",
                 selector: [{[:subject], "sensor-2"}]
               )

      assert {:ok, ["kept", "removed"]} = Router.route(:sys.get_state(bus).router, second)
      assert {:ok, _} = Bus.publish(bus, [first, second])
      assert_received {:signal, ^second}
      assert_received {:signal, ^second}
      refute_received {:signal, _}
      assert :ok = Bus.delete_subscription(bus, "removed")
      assert :ok = Bus.delete_subscription(bus, "kept")
      assert :sys.get_state(bus).monitors == %{}
      assert Router.empty?(:sys.get_state(bus).router)
    end
  end

  test "target exit removes only its selector and rejects duplicate IDs without changing selection" do
    bus = start_bus()
    target = start_target(:gone)

    assert {:ok, "gone"} =
             Bus.subscribe(bus, "sensor.*",
               target: target,
               subscription_id: "gone",
               selector: [{[:subject], "sensor-1"}]
             )

    assert {:ok, "kept"} =
             Bus.subscribe(bus, "sensor.*",
               subscription_id: "kept",
               selector: [{[:subject], "sensor-2"}]
             )

    before = :sys.get_state(bus)

    assert {:error, :subscription_already_exists} =
             Bus.subscribe(bus, "sensor.*",
               subscription_id: "kept",
               selector: [{[:subject], "sensor-1"}]
             )

    assert :sys.get_state(bus) == before
    terminate_and_wait(bus, target)
    state = :sys.get_state(bus)
    refute Map.has_key?(state.subscriptions, "gone")
    assert map_size(state.monitors) == 1
    first = subject_signal("sensor.updated", "sensor-1")
    second = subject_signal("sensor.updated", "sensor-2")
    assert {:error, _} = Router.route(state.router, first)
    assert {:ok, ["kept"]} = Router.route(state.router, second)
    assert {:ok, _} = Bus.publish(bus, [first, second])
    assert_received {:signal, ^second}
    refute_received {:signal, _}
  end

  test "Router fails closed if an internal selector cannot be evaluated" do
    event = signal("sensor.updated")

    assert {:ok, router} =
             Router.new([
               {"**", {Selector, :matches?, [[{:invalid, "value"}]]}, :invalid},
               {"**", {Selector, :matches?, [:invalid]}, :failure},
               {"**", :default}
             ])

    assert {:ok, [:default]} = Router.route(router, event)
  end

  defp start_bus, do: start_supervised!({Bus, name: unique_name("selector")})

  defp subject_signal(type, subject),
    do: Signal.new!(type, %{}, source: "/test", subject: subject)

  defp start_target(tag) do
    observer = self()
    target = spawn(fn -> target_loop(observer, tag) end)
    on_exit(fn -> if Process.alive?(target), do: Process.exit(target, :kill) end)
    target
  end

  defp target_loop(observer, tag) do
    receive do
      {:signal, event} ->
        send(observer, {:observed, tag, event})
        target_loop(observer, tag)

      {:barrier, caller, ref} ->
        send(caller, {:barrier, ref})
        target_loop(observer, tag)
    end
  end

  defp barrier(target) do
    ref = make_ref()
    send(target, {:barrier, self(), ref})
    assert_receive {:barrier, ^ref}
  end
end
