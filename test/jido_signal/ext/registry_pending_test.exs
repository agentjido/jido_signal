defmodule Jido.Signal.Ext.RegistryPendingTest do
  use ExUnit.Case, async: false

  alias Jido.Signal.Ext.Registry

  @pending_key {Registry, :pending_registrations}

  defmodule PendingExtensionOne do
    def namespace, do: "pending.one"
  end

  defmodule PendingExtensionTwo do
    def namespace, do: "pending.two"
  end

  defmodule PendingExtensionRuntime do
    def namespace, do: "pending.runtime"
  end

  setup do
    :persistent_term.erase(@pending_key)

    on_exit(fn ->
      :persistent_term.erase(@pending_key)
    end)

    :ok
  end

  test "startup drains pending extension registrations" do
    test_registry_name = :"pending-registry-#{System.unique_integer([:positive])}"

    :persistent_term.put(
      @pending_key,
      MapSet.new([PendingExtensionOne, PendingExtensionOne, PendingExtensionTwo])
    )

    {:ok, pid} = Registry.start_link(name: test_registry_name)

    assert {:ok, PendingExtensionOne} =
             GenServer.call(test_registry_name, {:get, PendingExtensionOne.namespace()})

    assert {:ok, PendingExtensionTwo} =
             GenServer.call(test_registry_name, {:get, PendingExtensionTwo.namespace()})

    assert :error = GenServer.call(test_registry_name, {:get, "non-existent"})
    assert :undefined == :persistent_term.get(@pending_key, :undefined)

    GenServer.stop(pid)
  end

  test "register remains safe while registry process is restarting" do
    registry_pid = Process.whereis(Registry)
    assert is_pid(registry_pid)

    Process.exit(registry_pid, :kill)
    Process.sleep(10)

    assert :ok = Registry.register(PendingExtensionRuntime)

    assert_eventually(fn ->
      match?({:ok, PendingExtensionRuntime}, Registry.get(PendingExtensionRuntime.namespace()))
    end)
  end

  defp assert_eventually(fun, attempts \\ 30)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0) do
    flunk("condition did not become true in time")
  end
end
