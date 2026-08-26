defmodule Jido.Signal.Dispatch.PidAdapterTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Dispatch

  defmodule Receiver do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

    @impl true
    def init(opts), do: {:ok, Keyword.fetch!(opts, :owner)}

    @impl true
    def handle_call(message, _from, owner) do
      send(owner, {:received_call, message})
      {:reply, :ok, owner}
    end

    @impl true
    def handle_info(message, owner) do
      send(owner, {:received_message, message})
      {:noreply, owner}
    end
  end

  test "parses PID and named targets through one Zoi schema" do
    assert {:ok, {:pid, pid_opts}} = Dispatch.validate_opts({:pid, target: self()})
    assert pid_opts == [target: self(), delivery_mode: :async, timeout: 5_000]

    assert {:ok, {:named, named_opts}} =
             Dispatch.validate_opts({:named, target: {:name, __MODULE__}})

    assert named_opts == [
             target: {:name, __MODULE__},
             delivery_mode: :async,
             timeout: 5_000
           ]

    assert {:error, reason} = Dispatch.validate_opts({:named, target: {:name, nil}})
    assert reason =~ "registered name"
  end

  test "delivers async and sync messages to a PID" do
    receiver = start_supervised!({Receiver, owner: self()})
    signal = signal()

    assert :ok = Dispatch.dispatch(signal, {:pid, target: receiver})
    assert_receive {:received_message, {:signal, ^signal}}

    assert :ok =
             Dispatch.dispatch(
               signal,
               {:pid, target: receiver, message_format: &{:custom, &1}}
             )

    assert_receive {:received_message, {:custom, ^signal}}

    assert :ok = Dispatch.dispatch(signal, {:pid, target: receiver, delivery_mode: :sync})
    assert_receive {:received_call, {:signal, ^signal}}
  end

  test "resolves a registered process for named delivery" do
    name = Module.concat(__MODULE__, "Receiver#{System.unique_integer([:positive])}")
    receiver = start_supervised!({Receiver, owner: self(), name: name})
    assert Process.whereis(name) == receiver
    signal = signal()

    assert :ok = Dispatch.dispatch(signal, {:named, target: {:name, name}})
    assert_receive {:received_message, {:signal, ^signal}}

    assert :ok =
             Dispatch.dispatch(signal, {:named, target: {:name, name}, delivery_mode: :sync})

    assert_receive {:received_call, {:signal, ^signal}}
  end

  test "returns stable errors for missing and dead processes" do
    signal = signal()
    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, _reason}

    assert {:error, :process_not_alive} = Dispatch.dispatch(signal, {:pid, target: dead})

    assert {:error, :process_not_found} =
             Dispatch.dispatch(signal, {:named, target: {:name, :missing_signal_target}})
  end

  test "does not call the current process synchronously" do
    signal = signal()

    assert {:error, {:calling_self, {GenServer, :call, [pid, {:signal, ^signal}, 5_000]}}} =
             Dispatch.dispatch(signal, {:pid, target: self(), delivery_mode: :sync})

    assert pid == self()
  end

  defp signal, do: Signal.new!("dispatch.process", %{}, source: "/test")
end
