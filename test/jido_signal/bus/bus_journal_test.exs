defmodule JidoTest.Signal.Bus.JournalConfigTest do
  use ExUnit.Case, async: false

  alias Jido.Signal.Bus
  alias Jido.Signal.Journal.Adapters.ETS, as: ETSAdapter
  alias Jido.Signal.Journal.Adapters.InMemory
  alias Jido.Signal.Names

  defmodule TrackingJournalAdapter do
    def init do
      {:ok, pid} = InMemory.init()

      case Application.get_env(:jido_signal, :tracking_journal_notify_pid) do
        notify_pid when is_pid(notify_pid) -> send(notify_pid, {:tracking_journal_pid, pid})
        _ -> :ok
      end

      {:ok, pid}
    end
  end

  defmodule InitFailMiddleware do
    def init(_opts), do: {:error, :init_failed}
  end

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

    test "fails when journal_pid is provided without journal_adapter" do
      bus_name = :"test_bus_invalid_journal_pair_#{:erlang.unique_integer([:positive])}"
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          send(parent, {:start_result, Bus.start_link(name: bus_name, journal_pid: self())})
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid,
                      {:bus_init_failed, :journal_pid_without_adapter}}

      refute_receive {:start_result, _}
    end

    test "failed bus init does not leak runtime supervisor children" do
      bus_name = :"test_bus_init_leak_#{:erlang.unique_integer([:positive])}"
      runtime_supervisor = Names.bus_runtime_supervisor([])

      before_children =
        runtime_supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 1))

      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          send(parent, {:start_result, Bus.start_link(name: bus_name, journal_pid: self())})
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid,
                      {:bus_init_failed, :journal_pid_without_adapter}}

      refute_receive {:start_result, _}

      after_children = runtime_supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 1))
      assert Enum.sort(after_children) == Enum.sort(before_children)
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
      assert state.journal_owned? == true

      GenServer.stop(bus_pid)
    end

    test "stopping bus terminates owned journal process" do
      bus_name = :"test_bus_owned_journal_#{:erlang.unique_integer([:positive])}"

      {:ok, bus_pid} = Bus.start_link(name: bus_name, journal_adapter: InMemory)
      state = :sys.get_state(bus_pid)
      journal_pid = state.journal_pid

      assert state.journal_owned? == true
      assert is_pid(journal_pid)

      journal_ref = Process.monitor(journal_pid)
      GenServer.stop(bus_pid)

      assert_receive {:DOWN, ^journal_ref, :process, ^journal_pid, _reason}, 1_000
    end

    test "stopping bus does not terminate externally managed journal process" do
      bus_name = :"test_bus_external_journal_#{:erlang.unique_integer([:positive])}"
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

      GenServer.stop(bus_pid)
      assert Process.alive?(external_journal_pid)

      GenServer.stop(external_journal_pid)
    end

    test "owned journal process is terminated when bus init fails after journal startup" do
      bus_name = :"test_bus_journal_cleanup_#{:erlang.unique_integer([:positive])}"
      parent = self()
      Application.put_env(:jido_signal, :tracking_journal_notify_pid, parent)

      on_exit(fn ->
        Application.delete_env(:jido_signal, :tracking_journal_notify_pid)
      end)

      {pid, ref} =
        spawn_monitor(fn ->
          send(
            parent,
            {:start_result,
             Bus.start_link(
               name: bus_name,
               journal_adapter: TrackingJournalAdapter,
               middleware: [{InitFailMiddleware, []}]
             )}
          )
        end)

      assert_receive {:tracking_journal_pid, journal_pid}
      journal_ref = Process.monitor(journal_pid)

      assert_receive {:DOWN, ^ref, :process, ^pid,
                      {:bus_init_failed,
                       {:middleware_init_failed, InitFailMiddleware, :init_failed}}}

      assert_receive {:DOWN, ^journal_ref, :process, ^journal_pid, _reason}
      refute_receive {:start_result, _}
    end

    test "middleware init failure does not leak runtime supervisor children" do
      bus_name = :"test_bus_middleware_init_leak_#{:erlang.unique_integer([:positive])}"
      runtime_supervisor = Names.bus_runtime_supervisor([])

      before_children =
        runtime_supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 1))

      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          send(
            parent,
            {:start_result,
             Bus.start_link(name: bus_name, middleware: [{InitFailMiddleware, []}])}
          )
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid,
                      {:bus_init_failed,
                       {:middleware_init_failed, InitFailMiddleware, :init_failed}}}

      refute_receive {:start_result, _}

      after_children = runtime_supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 1))
      assert Enum.sort(after_children) == Enum.sort(before_children)
    end
  end
end
