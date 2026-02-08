defmodule Jido.Signal.Ext.RegistryPendingTest do
  use ExUnit.Case, async: false

  alias Jido.Signal.Ext.Registry
  alias Jido.Signal.Ext.Trace
  alias Jido.Signal.Instance

  test "queues registrations when registry is unavailable and drains on start" do
    instance = :"PendingRegistry#{System.unique_integer([:positive])}"

    assert :ok = Registry.register(Trace, jido: instance)

    assert {:ok, _pid} = Instance.start_link(name: instance)

    assert {:ok, Trace} =
             Registry.get(Trace.namespace(), jido: instance)

    assert :ok = Instance.stop(instance)
  end
end
