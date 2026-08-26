defmodule Jido.Signal.Dispatch.NamedTest do
  use ExUnit.Case, async: false

  alias Jido.Signal
  alias Jido.Signal.Dispatch.Named

  defmodule TestGenServer do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    @impl true
    def init(:ok), do: {:ok, %{signals: [], mode: :unknown}}

    @impl true
    def handle_call(:get_signals, _from, state) do
      {:reply, {state.mode, Enum.reverse(state.signals)}, state}
    end

    @impl true
    def handle_call({:signal, signal}, _from, state) do
      new_state = %{signals: [signal | state.signals], mode: :sync}
      {:reply, {:ok, signal}, new_state}
    end

    @impl true
    def handle_info({:signal, signal}, state) do
      new_state = %{signals: [signal | state.signals], mode: :async}
      {:noreply, new_state}
    end

    def get_signals(pid) do
      GenServer.call(pid, :get_signals)
    end
  end

  describe "validate_opts/1" do
    test "accepts valid name tuple" do
      assert {:ok, opts} = Named.validate_opts(target: {:name, :my_process})
      assert opts[:target] == {:name, :my_process}
      assert opts[:delivery_mode] == :async
    end

    test "accepts sync delivery mode" do
      assert {:ok, opts} =
               Named.validate_opts(target: {:name, :my_process}, delivery_mode: :sync)

      assert opts[:delivery_mode] == :sync
    end

    test "rejects invalid target format" do
      for target <- [:invalid, {:invalid, :name}, {:name, "string"}] do
        assert {:error, error} = Named.validate_opts(target: target)
        assert error =~ "target"
      end
    end

    test "rejects invalid delivery mode" do
      assert {:error, error} =
               Named.validate_opts(target: {:name, :test}, delivery_mode: :invalid)

      assert error =~ "delivery_mode"
    end

    test "requires target option" do
      assert {:error, error} = Named.validate_opts([])
      assert error =~ "target"
    end
  end

  describe "deliver/2 async mode" do
    test "delivers signal to named process" do
      parent = self()
      name = :"test_async_process_#{:erlang.unique_integer([:positive])}"

      {:ok, _pid} =
        Agent.start_link(fn -> [] end, name: name)

      signal = Signal.new("test.signal", %{data: "test"})

      custom_format = fn sig ->
        send(parent, {:delivered, sig})
        {:signal, sig}
      end

      opts = [
        target: {:name, name},
        delivery_mode: :async,
        message_format: custom_format
      ]

      assert :ok = Named.deliver(signal, opts)

      assert_receive {:delivered, ^signal}, 1000
    end

    test "returns error when process not found" do
      signal = Signal.new("test.signal", %{data: "test"})

      opts = [
        target: {:name, :nonexistent_process},
        delivery_mode: :async
      ]

      assert {:error, :process_not_found} = Named.deliver(signal, opts)
    end

    test "returns error when process not alive" do
      name = :"test_dead_process_#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = Agent.start_link(fn -> [] end, name: name)

      ref = Process.monitor(pid)
      Process.unlink(pid)
      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1000

      signal = Signal.new("test.signal", %{data: "test"})

      opts = [
        target: {:name, name},
        delivery_mode: :async
      ]

      assert {:error, :process_not_found} = Named.deliver(signal, opts)
    end
  end

  describe "deliver/2 sync mode" do
    test "delivers signal and receives response" do
      name = :"test_sync_process_#{:erlang.unique_integer([:positive])}"
      {:ok, _pid} = TestGenServer.start_link(name: name)
      signal = Signal.new("test.signal", %{data: "test"})

      opts = [
        target: {:name, name},
        delivery_mode: :sync,
        timeout: 5000
      ]

      assert {:ok, ^signal} = Named.deliver(signal, opts)
    end

    test "returns error when process not found" do
      name = :"nonexistent_sync_process_#{:erlang.unique_integer([:positive])}"
      signal = Signal.new("test.signal", %{data: "test"})

      opts = [
        target: {:name, name},
        delivery_mode: :sync
      ]

      assert {:error, :process_not_found} = Named.deliver(signal, opts)
    end

    test "returns timeout error when call times out" do
      defmodule SlowServer do
        use GenServer

        def start_link(opts) do
          GenServer.start_link(__MODULE__, :ok, opts)
        end

        @impl true
        def init(:ok), do: {:ok, nil}

        @impl true
        def handle_call({:signal, _signal}, _from, state) do
          :timer.sleep(1000)
          {:reply, :ok, state}
        end
      end

      name = :"slow_process_#{:erlang.unique_integer([:positive])}"
      {:ok, _pid} = SlowServer.start_link(name: name)
      signal = Signal.new("test.signal", %{data: "test"})

      opts = [
        target: {:name, name},
        delivery_mode: :sync,
        timeout: 50
      ]

      assert {:error, :timeout} = Named.deliver(signal, opts)
    end

    test "detects self-call and returns error instead of deadlocking" do
      name = :"self_caller_#{:erlang.unique_integer([:positive])}"
      Process.register(self(), name)
      signal = Signal.new("test.signal", %{data: "test"})

      opts = [
        target: {:name, name},
        delivery_mode: :sync,
        timeout: 5000
      ]

      assert {:error, {:calling_self, {GenServer, :call, [pid, _message, 5000]}}} =
               Named.deliver(signal, opts)

      assert pid == self()
      Process.unregister(name)
    end
  end

  describe "deliver/2 with custom message format" do
    test "uses custom message format in async mode" do
      parent = self()
      name = :"test_custom_async_#{:erlang.unique_integer([:positive])}"
      {:ok, _pid} = Agent.start_link(fn -> [] end, name: name)
      signal = Signal.new("test.signal", %{data: "test"})

      custom_format = fn sig ->
        send(parent, {:custom_formatted, sig})
        {:custom_signal, sig}
      end

      opts = [
        target: {:name, name},
        delivery_mode: :async,
        message_format: custom_format
      ]

      assert :ok = Named.deliver(signal, opts)
      assert_receive {:custom_formatted, ^signal}, 1000
    end

    test "uses custom message format in sync mode" do
      name = :"test_custom_sync_#{:erlang.unique_integer([:positive])}"
      {:ok, _pid} = TestGenServer.start_link(name: name)
      signal = Signal.new("test.signal", %{data: "test"})

      custom_format = fn sig -> {:signal, sig} end

      opts = [
        target: {:name, name},
        delivery_mode: :sync,
        message_format: custom_format
      ]

      assert {:ok, ^signal} = Named.deliver(signal, opts)
    end
  end
end
