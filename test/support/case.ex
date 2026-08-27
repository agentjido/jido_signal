defmodule JidoSignalTest.Case do
  @moduledoc false

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  using do
    quote do
      import JidoSignalTest.Case
      import JidoSignalTest.Fixtures.Signals
    end
  end

  def unique_name(prefix) when is_binary(prefix) do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end

  defmacro unique_module(prefix) do
    namespace = __CALLER__.module

    quote bind_quoted: [namespace: namespace, prefix: prefix] do
      Module.concat(namespace, :"#{prefix}#{System.unique_integer([:positive])}")
    end
  end

  def create_module(module, quoted) do
    assert {:module, ^module, _bytecode, _term} =
             Module.create(module, quoted, Macro.Env.location(__ENV__))
  end

  def terminate_and_wait(server, target) when is_pid(server) and is_pid(target) do
    monitor = Process.monitor(target)
    :erlang.trace(server, true, [:receive])

    try do
      Process.exit(target, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^target, :killed}, 1_000

      assert_receive {:trace, ^server, :receive, {:DOWN, _ref, :process, ^target, :killed}},
                     1_000

      :sys.get_state(server)
      :ok
    after
      :erlang.trace(server, false, [:receive])
    end
  end
end
