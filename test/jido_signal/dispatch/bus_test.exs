defmodule Jido.Signal.Dispatch.BusTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias Jido.Signal.Dispatch

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
      assert {:ok, {:bus, opts}} = Dispatch.validate_opts({:bus, target: :my_bus})
      assert opts[:target] == :my_bus
      assert opts[:jido] == nil
    end

    test "accepts a target with a jido scope" do
      assert {:ok, {:bus, opts}} =
               Dispatch.validate_opts({:bus, target: :my_bus, jido: MyApp.Jido})

      assert opts[:target] == :my_bus
      assert opts[:jido] == MyApp.Jido
    end

    test "rejects nil target" do
      assert {:error, error} = Dispatch.validate_opts({:bus, target: nil})
      assert error =~ "target"
    end

    test "rejects non-atom target" do
      assert {:error, error} = Dispatch.validate_opts({:bus, target: "my_bus"})
      assert error =~ "target"
    end

    test "rejects missing target" do
      assert {:error, error} = Dispatch.validate_opts({:bus, []})
      assert error =~ "target"
    end

    test "rejects non-atom jido" do
      assert {:error, error} =
               Dispatch.validate_opts({:bus, target: :my_bus, jido: "invalid"})

      assert error =~ "jido"
    end
  end

  describe "deliver/2" do
    setup do
      bus_name = __MODULE__.DefaultBus
      start_supervised!({Bus, name: bus_name})
      {:ok, bus_name: bus_name}
    end

    test "delivers signal to a running bus", %{bus_name: bus_name} do
      signal = make_signal()

      # Subscribe to receive signals
      {:ok, _sub_id} = Bus.subscribe(bus_name, "test.signal")

      assert :ok = Dispatch.dispatch(signal, {:bus, target: bus_name})

      assert_received {:signal, received_signal}
      assert received_signal.type == "test.signal"
    end

    @tag :capture_log
    test "returns error when bus not found" do
      signal = make_signal()

      assert {:error, :bus_not_found} =
               Dispatch.dispatch(signal, {:bus, target: :nonexistent_bus_xyz})
    end
  end

  describe "deliver/2 with a jido scope" do
    setup do
      scope = __MODULE__.Isolated
      bus_name = __MODULE__.IsolatedBus
      start_supervised!({Bus, name: bus_name, jido: scope})

      {:ok, bus_name: bus_name, scope: scope}
    end

    test "delivers a signal to a scoped Bus", %{bus_name: bus_name, scope: scope} do
      signal = make_signal()

      {:ok, bus_pid} = Bus.whereis(bus_name, jido: scope)
      {:ok, _sub_id} = Bus.subscribe(bus_pid, "test.signal")

      assert :ok = Dispatch.dispatch(signal, {:bus, target: bus_name, jido: scope})

      assert_received {:signal, received_signal}
      assert received_signal.type == "test.signal"
    end

    @tag :capture_log
    test "returns an error when the Bus is not in the scope" do
      signal = make_signal()

      assert {:error, :bus_not_found} =
               Dispatch.dispatch(
                 signal,
                 {:bus, target: :nonexistent_bus, jido: __MODULE__.Missing}
               )
    end
  end

  describe "dispatch integration" do
    setup do
      bus_name = __MODULE__.DispatchBus
      start_supervised!({Bus, name: bus_name})
      {:ok, bus_name: bus_name}
    end

    test "dispatches via :bus adapter alias", %{bus_name: bus_name} do
      signal = make_signal()

      {:ok, _sub_id} = Bus.subscribe(bus_name, "test.signal")

      assert :ok = Dispatch.dispatch(signal, {:bus, [target: bus_name]})

      assert_received {:signal, received_signal}
      assert received_signal.type == "test.signal"
    end
  end
end
