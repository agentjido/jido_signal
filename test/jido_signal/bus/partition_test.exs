defmodule JidoTest.Signal.Bus.PartitionTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias Jido.Signal.Bus.Partition

  @moduletag :capture_log

  describe "rate limiting" do
    test "rate limiting triggers when burst size exceeded" do
      bus_name = :"test-bus-rate-limit-#{:erlang.unique_integer([:positive])}"

      start_supervised!(
        {Bus,
         name: bus_name,
         partition_count: 2,
         partition_rate_limit_per_sec: 10,
         partition_burst_size: 5}
      )

      test_pid = self()
      handler_id = "test-rate-limit-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:jido, :signal, :bus, :rate_limited],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:rate_limited, event, measurements, metadata})
        end,
        nil
      )

      {:ok, _subscription} = Bus.subscribe(bus_name, "test.signal")

      signals =
        for i <- 1..20 do
          {:ok, signal} =
            Signal.new(%{type: "test.signal", source: "/test", data: %{value: i}})

          signal
        end

      {:ok, _} = Bus.publish(bus_name, signals)

      assert_receive {:rate_limited, [:jido, :signal, :bus, :rate_limited], measurements,
                      metadata},
                     1000

      assert measurements.dropped_count > 0
      assert Map.has_key?(metadata, :partition_id)
      assert Map.has_key?(metadata, :available_tokens)
      assert Map.has_key?(metadata, :requested)

      :telemetry.detach(handler_id)
    end

    test "token refill allows more signals after waiting" do
      bus_name = :"test-bus-refill-#{:erlang.unique_integer([:positive])}"

      start_supervised!(
        {Bus,
         name: bus_name,
         partition_count: 2,
         partition_rate_limit_per_sec: 100,
         partition_burst_size: 5}
      )

      {:ok, _subscription} = Bus.subscribe(bus_name, "test.signal")

      signals1 =
        for i <- 1..5 do
          {:ok, signal} =
            Signal.new(%{type: "test.signal", source: "/test", data: %{value: i}})

          signal
        end

      {:ok, _} = Bus.publish(bus_name, signals1)

      for _ <- 1..5 do
        assert_receive {:signal, %Signal{type: "test.signal"}}, 500
      end

      Process.sleep(100)

      signals2 =
        for i <- 6..10 do
          {:ok, signal} =
            Signal.new(%{type: "test.signal", source: "/test", data: %{value: i}})

          signal
        end

      {:ok, _} = Bus.publish(bus_name, signals2)

      received_count =
        Enum.reduce(1..10, 0, fn _, acc ->
          receive do
            {:signal, %Signal{type: "test.signal"}} -> acc + 1
          after
            200 -> acc
          end
        end)

      assert received_count >= 5
    end

    test "burst handling allows configured burst_size signals at once" do
      bus_name = :"test-bus-burst-#{:erlang.unique_integer([:positive])}"

      start_supervised!(
        {Bus,
         name: bus_name,
         partition_count: 2,
         partition_rate_limit_per_sec: 10,
         partition_burst_size: 50}
      )

      {:ok, _subscription} = Bus.subscribe(bus_name, "test.signal")

      signals =
        for i <- 1..40 do
          {:ok, signal} =
            Signal.new(%{type: "test.signal", source: "/test", data: %{value: i}})

          signal
        end

      {:ok, _} = Bus.publish(bus_name, signals)

      received_count =
        Enum.reduce(1..50, 0, fn _, acc ->
          receive do
            {:signal, %Signal{type: "test.signal"}} -> acc + 1
          after
            200 -> acc
          end
        end)

      assert received_count >= 30
    end

    test "telemetry event contains correct metadata" do
      bus_name = :"test-bus-telemetry-rate-#{:erlang.unique_integer([:positive])}"

      start_supervised!(
        {Bus,
         name: bus_name,
         partition_count: 2,
         partition_rate_limit_per_sec: 5,
         partition_burst_size: 2}
      )

      test_pid = self()
      handler_id = "test-rate-limit-meta-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:jido, :signal, :bus, :rate_limited],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:rate_limited_meta, measurements, metadata})
        end,
        nil
      )

      {:ok, _subscription} = Bus.subscribe(bus_name, "test.signal")

      signals =
        for i <- 1..10 do
          {:ok, signal} =
            Signal.new(%{type: "test.signal", source: "/test", data: %{value: i}})

          signal
        end

      {:ok, _} = Bus.publish(bus_name, signals)

      assert_receive {:rate_limited_meta, measurements, metadata}, 1000

      assert is_integer(measurements.dropped_count)
      assert measurements.dropped_count > 0
      assert metadata.bus_name == bus_name
      assert is_integer(metadata.partition_id)
      assert metadata.partition_id >= 0 and metadata.partition_id < 2
      assert is_float(metadata.available_tokens)
      assert is_integer(metadata.requested)

      :telemetry.detach(handler_id)
    end
  end

  describe "partition_for/2" do
    test "returns 0 when partition_count is 1" do
      assert Partition.partition_for("any-subscription-id", 1) == 0
    end

    test "returns consistent partition for same subscription_id" do
      subscription_id = "test-sub-123"
      partition_count = 4

      partition1 = Partition.partition_for(subscription_id, partition_count)
      partition2 = Partition.partition_for(subscription_id, partition_count)
      partition3 = Partition.partition_for(subscription_id, partition_count)

      assert partition1 == partition2
      assert partition2 == partition3
      assert partition1 >= 0 and partition1 < partition_count
    end

    test "distributes subscriptions across partitions" do
      partition_count = 4
      subscription_ids = for i <- 1..100, do: "sub-#{i}"

      partitions =
        subscription_ids
        |> Enum.map(&Partition.partition_for(&1, partition_count))
        |> Enum.frequencies()

      # All partitions should be used
      assert map_size(partitions) == partition_count

      # Distribution should be reasonably even (each partition gets at least 10%)
      Enum.each(partitions, fn {_partition, count} ->
        assert count >= 10
      end)
    end
  end

  describe "backward compatibility with partition_count: 1" do
    setup do
      bus_name = :"test-bus-partition-1-#{:erlang.unique_integer([:positive])}"
      start_supervised!({Bus, name: bus_name, partition_count: 1})
      {:ok, bus: bus_name}
    end

    test "subscribes and receives signals", %{bus: bus} do
      {:ok, _subscription} = Bus.subscribe(bus, "test.signal")

      {:ok, signal} =
        Signal.new(%{
          type: "test.signal",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, _} = Bus.publish(bus, [signal])
      assert_receive {:signal, %Signal{type: "test.signal"}}
    end

    test "multiple subscriptions receive appropriate signals", %{bus: bus} do
      {:ok, _sub1} = Bus.subscribe(bus, "test.signal.1")
      {:ok, _sub2} = Bus.subscribe(bus, "test.signal.2")
      {:ok, _sub3} = Bus.subscribe(bus, "test.**")

      {:ok, signal1} =
        Signal.new(%{
          type: "test.signal.1",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, signal2} =
        Signal.new(%{
          type: "test.signal.2",
          source: "/test",
          data: %{value: 2}
        })

      {:ok, _} = Bus.publish(bus, [signal1, signal2])

      # Should receive signal1 twice (from sub1 and sub3)
      assert_receive {:signal, %Signal{type: "test.signal.1"}}
      assert_receive {:signal, %Signal{type: "test.signal.1"}}

      # Should receive signal2 twice (from sub2 and sub3)
      assert_receive {:signal, %Signal{type: "test.signal.2"}}
      assert_receive {:signal, %Signal{type: "test.signal.2"}}
    end
  end

  describe "partitioned bus with partition_count: 4" do
    setup do
      bus_name = :"test-bus-partition-4-#{:erlang.unique_integer([:positive])}"
      start_supervised!({Bus, name: bus_name, partition_count: 4})
      {:ok, bus: bus_name}
    end

    test "subscribes and receives signals", %{bus: bus} do
      {:ok, _subscription} = Bus.subscribe(bus, "test.signal")

      {:ok, signal} =
        Signal.new(%{
          type: "test.signal",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, _} = Bus.publish(bus, [signal])

      # Allow time for async dispatch from partitions
      assert_receive {:signal, %Signal{type: "test.signal"}}, 1000
    end

    test "multiple subscriptions are distributed across partitions", %{bus: bus} do
      # Create multiple subscriptions
      subscription_ids =
        for i <- 1..8 do
          {:ok, sub_id} = Bus.subscribe(bus, "test.signal.#{i}")
          sub_id
        end

      # Verify all subscriptions were created
      assert length(subscription_ids) == 8

      # Verify subscriptions are distributed across partitions
      partitions =
        subscription_ids
        |> Enum.map(&Partition.partition_for(&1, 4))
        |> Enum.frequencies()

      # At least 2 different partitions should be used
      assert map_size(partitions) >= 2
    end

    test "each subscription receives appropriate signals", %{bus: bus} do
      {:ok, _sub1} = Bus.subscribe(bus, "test.signal.1")
      {:ok, _sub2} = Bus.subscribe(bus, "test.signal.2")

      {:ok, signal1} =
        Signal.new(%{
          type: "test.signal.1",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, signal2} =
        Signal.new(%{
          type: "test.signal.2",
          source: "/test",
          data: %{value: 2}
        })

      {:ok, _} = Bus.publish(bus, [signal1, signal2])

      # Allow time for async dispatch
      assert_receive {:signal, %Signal{type: "test.signal.1"}}, 1000
      assert_receive {:signal, %Signal{type: "test.signal.2"}}, 1000

      # Should not receive other types
      refute_receive {:signal, _}
    end

    test "wildcard subscriptions work correctly", %{bus: bus} do
      {:ok, _sub} = Bus.subscribe(bus, "test.**")

      {:ok, signal1} =
        Signal.new(%{
          type: "test.signal.1",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, signal2} =
        Signal.new(%{
          type: "test.signal.2",
          source: "/test",
          data: %{value: 2}
        })

      {:ok, signal3} =
        Signal.new(%{
          type: "other.signal",
          source: "/test",
          data: %{value: 3}
        })

      {:ok, _} = Bus.publish(bus, [signal1, signal2, signal3])

      # Should receive test.signal.1 and test.signal.2
      assert_receive {:signal, %Signal{type: "test.signal.1"}}, 1000
      assert_receive {:signal, %Signal{type: "test.signal.2"}}, 1000

      # Should not receive other.signal
      refute_receive {:signal, %Signal{type: "other.signal"}}, 100
    end

    test "unsubscribe removes subscription from partition", %{bus: bus} do
      {:ok, sub_id} = Bus.subscribe(bus, "test.signal")

      {:ok, signal1} =
        Signal.new(%{
          type: "test.signal",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, _} = Bus.publish(bus, [signal1])
      assert_receive {:signal, %Signal{type: "test.signal"}}, 1000

      # Unsubscribe
      :ok = Bus.unsubscribe(bus, sub_id)

      # Drain any pending messages
      receive do
        {:signal, _} -> :ok
      after
        100 -> :ok
      end

      # Publish another signal
      {:ok, signal2} =
        Signal.new(%{
          type: "test.signal",
          source: "/test",
          data: %{value: 2}
        })

      {:ok, _} = Bus.publish(bus, [signal2])

      # Should not receive new signals
      refute_receive {:signal, _}, 200
    end
  end

  describe "persistent subscriptions with partitions" do
    setup do
      bus_name = :"test-bus-persistent-partition-#{:erlang.unique_integer([:positive])}"
      start_supervised!({Bus, name: bus_name, partition_count: 4})
      {:ok, bus: bus_name}
    end

    test "persistent subscriptions still work with backpressure", %{bus: bus} do
      {:ok, _subscription_id} =
        Bus.subscribe(bus, "test.signal",
          persistent?: true,
          max_in_flight: 1,
          max_pending: 1
        )

      {:ok, signal1} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 1}})
      {:ok, _} = Bus.publish(bus, [signal1])

      assert_receive {:signal, %Signal{type: "test.signal"}}

      {:ok, signal2} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 2}})
      {:ok, _} = Bus.publish(bus, [signal2])

      {:ok, signal3} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 3}})
      result = Bus.publish(bus, [signal3])

      assert {:error, error} = result
      assert error.message == "Subscription saturated"
    end
  end

  describe "telemetry events include partition_id" do
    setup do
      bus_name = :"test-bus-telemetry-partition-#{:erlang.unique_integer([:positive])}"
      start_supervised!({Bus, name: bus_name, partition_count: 2})
      {:ok, bus: bus_name}
    end

    test "dispatch telemetry includes partition_id", %{bus: bus} do
      test_pid = self()
      handler_id = "test-partition-telemetry-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:jido, :signal, :bus, :after_dispatch],
        fn event, measurements, metadata, config ->
          # Only forward events for our specific bus to avoid cross-test interference
          if metadata[:bus_name] == config.bus_name do
            send(config.test_pid, {:telemetry_event, event, measurements, metadata})
          end
        end,
        %{test_pid: test_pid, bus_name: bus}
      )

      {:ok, _subscription} = Bus.subscribe(bus, "test.signal")

      {:ok, signal} =
        Signal.new(%{
          type: "test.signal",
          source: "/test",
          data: %{value: 1}
        })

      {:ok, _} = Bus.publish(bus, [signal])

      assert_receive {:telemetry_event, [:jido, :signal, :bus, :after_dispatch], _measurements,
                      metadata},
                     1000

      assert Map.has_key?(metadata, :partition_id)
      assert metadata.partition_id >= 0 and metadata.partition_id < 2

      :telemetry.detach(handler_id)
    end
  end

  describe "partition restart handling" do
    setup do
      bus_name = :"test-bus-partition-restart-#{:erlang.unique_integer([:positive])}"
      start_supervised!({Bus, name: bus_name, partition_count: 2})
      {:ok, bus: bus_name}
    end

    test "bus uses current partition process for subscription updates after restart", %{bus: bus} do
      {:ok, subscription_id} = Bus.subscribe(bus, "test.signal")

      {:ok, bus_pid} = Bus.whereis(bus)
      bus_state = :sys.get_state(bus_pid)
      partition_id = Partition.partition_for(subscription_id, bus_state.partition_count)
      old_partition_pid = Enum.at(bus_state.partition_pids, partition_id)
      assert is_pid(old_partition_pid)

      Process.exit(old_partition_pid, :kill)
      Process.sleep(50)

      new_partition_pid = GenServer.whereis(Partition.via_tuple(bus, partition_id))
      assert is_pid(new_partition_pid)
      refute new_partition_pid == old_partition_pid

      # Old subscription was managed by previous partition process.
      # Unsubscribe should still succeed using current partition target resolution.
      assert :ok = Bus.unsubscribe(bus, subscription_id)

      # Re-subscribing should target the restarted partition process.
      {:ok, _new_subscription_id} = Bus.subscribe(bus, "test.signal")

      {:ok, signal} = Signal.new(%{type: "test.signal", source: "/test", data: %{value: 1}})
      assert {:ok, _} = Bus.publish(bus, [signal])
      assert_receive {:signal, %Signal{type: "test.signal"}}
    end
  end
end
