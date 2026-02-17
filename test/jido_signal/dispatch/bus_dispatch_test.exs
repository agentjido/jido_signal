defmodule Jido.Signal.Dispatch.BusTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias Jido.Signal.Dispatch
  alias Jido.Signal.Dispatch.Bus, as: BusAdapter
  alias Jido.Signal.Instance

  @moduletag :capture_log

  defp make_signal(type \\ "test.signal") do
    {:ok, signal} =
      Signal.new(%{
        type: type,
        source: "/test",
        data: %{value: 1}
      })

    signal
  end

  describe "validate_opts/1" do
    test "accepts valid target atom" do
      assert {:ok, opts} = BusAdapter.validate_opts(target: :my_bus)
      assert opts[:target] == :my_bus
      assert opts[:jido] == nil
    end

    test "accepts valid target with jido instance" do
      assert {:ok, opts} = BusAdapter.validate_opts(target: :my_bus, jido: MyApp.Jido)
      assert opts[:target] == :my_bus
      assert opts[:jido] == MyApp.Jido
    end

    test "rejects nil target" do
      assert {:error, "target must be a bus name atom"} = BusAdapter.validate_opts(target: nil)
    end

    test "rejects non-atom target" do
      assert {:error, "target must be a bus name atom"} =
               BusAdapter.validate_opts(target: "my_bus")
    end

    test "rejects missing target" do
      assert {:error, "target must be a bus name atom"} = BusAdapter.validate_opts([])
    end

    test "rejects non-atom jido" do
      assert {:error, "jido must be an atom or nil"} =
               BusAdapter.validate_opts(target: :my_bus, jido: "invalid")
    end
  end

  describe "deliver/2" do
    setup do
      bus_name = :"test_bus_#{System.unique_integer([:positive])}"
      start_supervised!({Bus, name: bus_name})
      {:ok, bus_name: bus_name}
    end

    test "delivers signal to a running bus", %{bus_name: bus_name} do
      signal = make_signal()

      # Subscribe to receive signals
      {:ok, _sub_id} = Bus.subscribe(bus_name, "test.signal")

      assert :ok = BusAdapter.deliver(signal, target: bus_name)

      assert_receive {:signal, received_signal}, 1000
      assert received_signal.type == "test.signal"
    end

    test "returns error when bus not found" do
      signal = make_signal()

      assert {:error, :bus_not_found} =
               BusAdapter.deliver(signal, target: :nonexistent_bus_xyz)
    end
  end

  describe "deliver/2 with instance isolation" do
    setup do
      instance = :"TestInstance_#{System.unique_integer([:positive])}"
      {:ok, sup} = Instance.start_link(name: instance)

      bus_name = :"isolated_bus_#{System.unique_integer([:positive])}"
      {:ok, _bus_pid} = Bus.start_link(name: bus_name, jido: instance)

      on_exit(fn ->
        try do
          if Process.alive?(sup), do: Supervisor.stop(sup, :normal, 100)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, bus_name: bus_name, instance: instance}
    end

    test "delivers signal to instance-scoped bus", %{bus_name: bus_name, instance: instance} do
      signal = make_signal()

      # Subscribe via the bus pid (already resolved)
      {:ok, bus_pid} = Bus.whereis(bus_name, jido: instance)
      {:ok, _sub_id} = Bus.subscribe(bus_pid, "test.signal")

      assert :ok = BusAdapter.deliver(signal, target: bus_name, jido: instance)

      assert_receive {:signal, received_signal}, 1000
      assert received_signal.type == "test.signal"
    end

    test "returns error when bus not in instance scope" do
      signal = make_signal()

      # Use a bogus instance that has no bus registered
      assert {:error, :bus_not_found} =
               BusAdapter.deliver(signal, target: :nonexistent_bus, jido: :"NoInstance_#{System.unique_integer([:positive])}")
    end
  end

  describe "dispatch integration" do
    setup do
      bus_name = :"dispatch_bus_#{System.unique_integer([:positive])}"
      start_supervised!({Bus, name: bus_name})
      {:ok, bus_name: bus_name}
    end

    test "dispatches via :bus adapter alias", %{bus_name: bus_name} do
      signal = make_signal()

      {:ok, _sub_id} = Bus.subscribe(bus_name, "test.signal")

      assert :ok = Dispatch.dispatch(signal, {:bus, [target: bus_name]})

      assert_receive {:signal, received_signal}, 1000
      assert received_signal.type == "test.signal"
    end
  end
end
