defmodule JidoTest.Signal.Bus.JournalConfigTest do
  use ExUnit.Case, async: false

  alias Jido.Signal.Bus
  alias Jido.Signal.Journal.Adapters.ETS, as: ETSAdapter
  alias Jido.Signal.Journal.Adapters.InMemory

  @moduletag :capture_log

  describe "journal adapter configuration" do
    test "starts with ETS journal adapter via start_link opts" do
      bus_name = :"test_bus_ets_#{:erlang.unique_integer([:positive])}"

      {:ok, bus_pid} =
        Bus.start_link(
          name: bus_name,
          journal_adapter: ETSAdapter,
          journal_adapter_opts: []
        )

      assert Process.alive?(bus_pid)

      # Verify journal_adapter is set in state
      state = :sys.get_state(bus_pid)
      assert state.journal_adapter == ETSAdapter
      assert is_pid(state.journal_pid)

      GenServer.stop(bus_pid)
    end

    test "starts with InMemory journal adapter via start_link opts" do
      bus_name = :"test_bus_inmemory_#{:erlang.unique_integer([:positive])}"

      {:ok, bus_pid} =
        Bus.start_link(
          name: bus_name,
          journal_adapter: InMemory,
          journal_adapter_opts: []
        )

      assert Process.alive?(bus_pid)

      # Verify journal_adapter is set in state
      state = :sys.get_state(bus_pid)
      assert state.journal_adapter == InMemory
      assert is_pid(state.journal_pid)

      GenServer.stop(bus_pid)
    end

    test "starts without journal adapter (backward compatible)" do
      bus_name = :"test_bus_no_adapter_#{:erlang.unique_integer([:positive])}"

      {:ok, bus_pid} = Bus.start_link(name: bus_name)

      assert Process.alive?(bus_pid)

      # Verify journal_adapter is nil
      state = :sys.get_state(bus_pid)
      assert state.journal_adapter == nil
      assert state.journal_pid == nil

      GenServer.stop(bus_pid)
    end

    test "uses application config for journal adapter when not specified in opts" do
      bus_name = :"test_bus_app_config_#{:erlang.unique_integer([:positive])}"

      # Set application config
      Application.put_env(:jido_signal, :journal_adapter, InMemory)

      on_exit(fn ->
        Application.delete_env(:jido_signal, :journal_adapter)
        Application.delete_env(:jido_signal, :journal_adapter_opts)
      end)

      {:ok, bus_pid} = Bus.start_link(name: bus_name)

      assert Process.alive?(bus_pid)

      # Verify journal adapter is InMemory from app config
      state = :sys.get_state(bus_pid)
      assert state.journal_adapter == InMemory
      assert is_pid(state.journal_pid)

      GenServer.stop(bus_pid)
    end

    test "start_link opts take precedence over application config" do
      bus_name = :"test_bus_opts_precedence_#{:erlang.unique_integer([:positive])}"

      # Set application config to InMemory
      Application.put_env(:jido_signal, :journal_adapter, InMemory)

      on_exit(fn ->
        Application.delete_env(:jido_signal, :journal_adapter)
      end)

      # But pass ETS in opts
      {:ok, bus_pid} =
        Bus.start_link(
          name: bus_name,
          journal_adapter: ETSAdapter
        )

      assert Process.alive?(bus_pid)

      # Verify ETS was used (from opts, not app config)
      state = :sys.get_state(bus_pid)
      assert state.journal_adapter == ETSAdapter
      assert is_pid(state.journal_pid)

      GenServer.stop(bus_pid)
    end

    test "stops owned journal process on bus termination" do
      bus_name = :"test_bus_owned_journal_stop_#{:erlang.unique_integer([:positive])}"

      {:ok, bus_pid} =
        Bus.start_link(
          name: bus_name,
          journal_adapter: InMemory
        )

      state = :sys.get_state(bus_pid)
      assert state.journal_owned? == true
      assert is_pid(state.journal_pid)
      assert Process.alive?(state.journal_pid)

      journal_pid = state.journal_pid
      GenServer.stop(bus_pid)

      refute Process.alive?(journal_pid)
    end

    test "does not stop externally provided journal process on bus termination" do
      bus_name = :"test_bus_external_journal_keep_#{:erlang.unique_integer([:positive])}"
      {:ok, external_journal_pid} = InMemory.init()

      {:ok, bus_pid} =
        Bus.start_link(
          name: bus_name,
          journal_adapter: InMemory,
          journal_pid: external_journal_pid
        )

      state = :sys.get_state(bus_pid)
      assert state.journal_owned? == false
      assert state.journal_pid == external_journal_pid
      assert Process.alive?(external_journal_pid)

      GenServer.stop(bus_pid)

      assert Process.alive?(external_journal_pid)
      GenServer.stop(external_journal_pid)
    end
  end
end
