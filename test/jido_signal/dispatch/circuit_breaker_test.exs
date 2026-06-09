defmodule Jido.Signal.Dispatch.CircuitBreakerTest do
  use ExUnit.Case, async: false

  alias Jido.Signal.Dispatch.CircuitBreaker
  alias Jido.Signal.Instance
  alias Jido.Signal.Names

  @test_adapter :test_circuit_adapter

  setup do
    adapter = :"#{@test_adapter}_#{:erlang.unique_integer([:positive])}"
    {:ok, adapter: adapter}
  end

  describe "install/2" do
    test "installs a circuit breaker", %{adapter: adapter} do
      assert :ok = CircuitBreaker.install(adapter)
      assert CircuitBreaker.installed?(adapter)
    end

    test "is idempotent - returns :ok if already installed", %{adapter: adapter} do
      assert :ok = CircuitBreaker.install(adapter)
      assert :ok = CircuitBreaker.install(adapter)
    end

    test "same configuration does not reset circuit state", %{adapter: adapter} do
      opts = [strategy: {:standard, 1, 5_000}, refresh: 30_000]

      assert :ok = CircuitBreaker.install(adapter, opts)
      assert {:error, :fail1} = CircuitBreaker.run(adapter, fn -> {:error, :fail1} end)
      assert CircuitBreaker.status(adapter) == :ok

      assert :ok = CircuitBreaker.install(adapter, opts)
      assert {:error, :fail2} = CircuitBreaker.run(adapter, fn -> {:error, :fail2} end)
      assert CircuitBreaker.status(adapter) == :blown
    end

    test "changed configuration resets circuit state", %{adapter: adapter} do
      assert :ok =
               CircuitBreaker.install(adapter, strategy: {:standard, 0, 5_000}, refresh: 30_000)

      assert {:error, :fail} = CircuitBreaker.run(adapter, fn -> {:error, :fail} end)
      assert CircuitBreaker.status(adapter) == :blown

      assert :ok =
               CircuitBreaker.install(adapter, strategy: {:standard, 1, 5_000}, refresh: 30_000)

      assert CircuitBreaker.status(adapter) == :ok

      assert {:error, :fail_after_reconfigure} =
               CircuitBreaker.run(adapter, fn -> {:error, :fail_after_reconfigure} end)

      assert CircuitBreaker.status(adapter) == :ok
    end

    test "accepts custom configuration", %{adapter: adapter} do
      opts = [
        strategy: {:standard, 2, 5_000},
        refresh: 10_000
      ]

      assert :ok = CircuitBreaker.install(adapter, opts)
      assert CircuitBreaker.installed?(adapter)
    end

    test "rejects unsupported strategy configuration", %{adapter: adapter} do
      opts = [strategy: {:fault_injection, 0.1, 2, 5_000}]

      assert {:error, {:invalid_strategy, {:fault_injection, 0.1, 2, 5_000}}} =
               CircuitBreaker.install(adapter, opts)

      refute CircuitBreaker.installed?(adapter)
    end

    test "rejects unknown options", %{adapter: adapter} do
      assert {:error, {:invalid_options, [:unknown]}} =
               CircuitBreaker.install(adapter, unknown: true)

      refute CircuitBreaker.installed?(adapter)
    end
  end

  describe "ensure_installed/2" do
    test "installs a missing circuit", %{adapter: adapter} do
      assert :ok = CircuitBreaker.ensure_installed(adapter)
      assert CircuitBreaker.installed?(adapter)
    end

    test "does not reset an existing circuit with different configuration", %{adapter: adapter} do
      assert :ok =
               CircuitBreaker.install(adapter, strategy: {:standard, 0, 5_000}, refresh: 30_000)

      assert :ok = CircuitBreaker.ensure_installed(adapter)

      assert {:error, :fail} = CircuitBreaker.run(adapter, fn -> {:error, :fail} end)
      assert CircuitBreaker.status(adapter) == :blown
    end
  end

  describe "run/2" do
    test "executes function when circuit is closed", %{adapter: adapter} do
      CircuitBreaker.install(adapter)

      result = CircuitBreaker.run(adapter, fn -> {:ok, :success} end)
      assert result == {:ok, :success}
    end

    test "returns :ok for successful functions returning :ok", %{adapter: adapter} do
      CircuitBreaker.install(adapter)

      result = CircuitBreaker.run(adapter, fn -> :ok end)
      assert result == :ok
    end

    test "records failure and returns error", %{adapter: adapter} do
      CircuitBreaker.install(adapter)

      result = CircuitBreaker.run(adapter, fn -> {:error, :some_error} end)
      assert result == {:error, :some_error}
    end

    test "handles exceptions", %{adapter: adapter} do
      CircuitBreaker.install(adapter)

      result =
        CircuitBreaker.run(adapter, fn ->
          raise "test exception"
        end)

      assert {:error, {:exception, "test exception"}} = result
    end
  end

  describe "circuit opens after failures" do
    test "opens circuit after threshold failures", %{adapter: adapter} do
      # {:standard, N, window} means: allow N failures, blow on N+1th
      CircuitBreaker.install(adapter, strategy: {:standard, 1, 5_000}, refresh: 30_000)

      # First failure - still within tolerance
      CircuitBreaker.run(adapter, fn -> {:error, :fail1} end)
      assert CircuitBreaker.status(adapter) == :ok

      # Second failure - exceeds threshold, circuit blows
      CircuitBreaker.run(adapter, fn -> {:error, :fail2} end)
      assert CircuitBreaker.status(adapter) == :blown
    end

    test "returns :circuit_open when circuit is open", %{adapter: adapter} do
      # Allow 0 failures (blow on first)
      CircuitBreaker.install(adapter, strategy: {:standard, 0, 5_000}, refresh: 30_000)

      # First failure blows the circuit
      CircuitBreaker.run(adapter, fn -> {:error, :fail} end)

      result = CircuitBreaker.run(adapter, fn -> {:ok, :should_not_run} end)
      assert result == {:error, :circuit_open}
    end

    test "does not count failures outside the configured window", %{adapter: adapter} do
      CircuitBreaker.install(adapter, strategy: {:standard, 1, 25}, refresh: 30_000)

      CircuitBreaker.run(adapter, fn -> {:error, :fail1} end)
      assert CircuitBreaker.status(adapter) == :ok

      Process.sleep(40)

      CircuitBreaker.run(adapter, fn -> {:error, :fail2} end)
      assert CircuitBreaker.status(adapter) == :ok
    end

    test "opens under concurrent failures", %{adapter: adapter} do
      CircuitBreaker.install(adapter, strategy: {:standard, 3, 1_000}, refresh: 30_000)

      1..8
      |> Enum.map(fn index ->
        Task.async(fn ->
          CircuitBreaker.run(adapter, fn -> {:error, {:fail, index}} end)
        end)
      end)
      |> Task.await_many()

      assert CircuitBreaker.status(adapter) == :blown
    end
  end

  describe "status/1" do
    test "returns :ok when circuit is closed", %{adapter: adapter} do
      CircuitBreaker.install(adapter)
      assert CircuitBreaker.status(adapter) == :ok
    end

    test "returns :blown when circuit is open", %{adapter: adapter} do
      # Allow 0 failures (blow on first)
      CircuitBreaker.install(adapter, strategy: {:standard, 0, 5_000}, refresh: 30_000)

      CircuitBreaker.run(adapter, fn -> {:error, :fail} end)

      assert CircuitBreaker.status(adapter) == :blown
    end
  end

  describe "reset/1" do
    test "resets an open circuit", %{adapter: adapter} do
      # Allow 0 failures (blow on first)
      CircuitBreaker.install(adapter, strategy: {:standard, 0, 5_000}, refresh: 30_000)

      CircuitBreaker.run(adapter, fn -> {:error, :fail} end)

      assert CircuitBreaker.status(adapter) == :blown

      assert :ok = CircuitBreaker.reset(adapter)
      assert CircuitBreaker.status(adapter) == :ok
    end

    test "allows requests after reset", %{adapter: adapter} do
      # Allow 0 failures (blow on first)
      CircuitBreaker.install(adapter, strategy: {:standard, 0, 5_000}, refresh: 30_000)

      CircuitBreaker.run(adapter, fn -> {:error, :fail} end)

      assert CircuitBreaker.status(adapter) == :blown

      CircuitBreaker.reset(adapter)

      result = CircuitBreaker.run(adapter, fn -> {:ok, :success} end)
      assert result == {:ok, :success}
    end

    test "ignores stale reset timers after reconfiguration", %{adapter: adapter} do
      CircuitBreaker.install(adapter, strategy: {:standard, 0, 5_000}, refresh: 40)
      CircuitBreaker.run(adapter, fn -> {:error, :fail} end)
      assert CircuitBreaker.status(adapter) == :blown

      CircuitBreaker.install(adapter, strategy: {:standard, 1, 5_000}, refresh: 500)
      assert CircuitBreaker.status(adapter) == :ok

      CircuitBreaker.run(adapter, fn -> {:error, :fail_after_reconfigure_1} end)
      CircuitBreaker.run(adapter, fn -> {:error, :fail_after_reconfigure_2} end)
      assert CircuitBreaker.status(adapter) == :blown

      Process.sleep(80)

      assert CircuitBreaker.status(adapter) == :blown
    end
  end

  describe "installed?/1" do
    test "returns true for installed circuit", %{adapter: adapter} do
      CircuitBreaker.install(adapter)
      assert CircuitBreaker.installed?(adapter) == true
    end

    test "returns false for non-installed circuit" do
      assert CircuitBreaker.installed?(:non_existent_adapter_xyz) == false
    end
  end

  describe "instance scoping" do
    test "isolates circuits between breaker servers", %{adapter: adapter} do
      instance_a = unique_instance()
      instance_b = unique_instance()
      start_supervised!({Instance, name: instance_a})
      start_supervised!({Instance, name: instance_b})
      server_a = Names.circuit_breaker(jido: instance_a)
      server_b = Names.circuit_breaker(jido: instance_b)

      opts = [strategy: {:standard, 0, 5_000}, refresh: 30_000]
      opts_a = Keyword.put(opts, :server, server_a)
      opts_b = Keyword.put(opts, :server, server_b)

      assert :ok = CircuitBreaker.install(adapter, opts_a)
      assert :ok = CircuitBreaker.install(adapter, opts_b)

      assert {:error, :fail} =
               CircuitBreaker.run(adapter, fn -> {:error, :fail} end, server: server_a)

      assert CircuitBreaker.status(adapter, server: server_a) == :blown
      assert CircuitBreaker.status(adapter, server: server_b) == :ok
      refute CircuitBreaker.installed?(adapter)
    end

    test "returns an error when scoped server is not running", %{adapter: adapter} do
      missing_server = unique_instance()

      assert {:error, :server_not_found} =
               CircuitBreaker.install(adapter, server: missing_server)

      assert CircuitBreaker.status(adapter, server: missing_server) ==
               {:error, :server_not_found}

      refute CircuitBreaker.installed?(adapter, server: missing_server)
    end

    test "drops scoped circuit state when the Jido instance stops", %{adapter: adapter} do
      instance = unique_instance()
      {:ok, supervisor} = Instance.start_link(name: instance)
      server = Names.circuit_breaker(jido: instance)
      opts = [strategy: {:standard, 0, 5_000}, refresh: 30_000, server: server]

      assert :ok = CircuitBreaker.install(adapter, opts)

      assert {:error, :fail} =
               CircuitBreaker.run(adapter, fn -> {:error, :fail} end, server: server)

      assert CircuitBreaker.status(adapter, server: server) == :blown

      assert :ok = Supervisor.stop(supervisor)
      assert CircuitBreaker.status(adapter, server: server) == {:error, :server_not_found}
    end

    test "rejects invalid server scope", %{adapter: adapter} do
      assert {:error, {:invalid_server, "bad"}} = CircuitBreaker.install(adapter, server: "bad")
      assert {:error, {:invalid_server, "bad"}} = CircuitBreaker.status(adapter, server: "bad")
      assert {:error, {:invalid_server, "bad"}} = CircuitBreaker.reset(adapter, server: "bad")

      assert {:error, {:invalid_server, "bad"}} =
               CircuitBreaker.run(adapter, fn -> :ok end, server: "bad")

      refute CircuitBreaker.installed?(adapter, server: "bad")
    end
  end

  describe "telemetry events" do
    test "emits melt event on failure", %{adapter: adapter} do
      test_pid = self()
      handler_id = "test-melt-#{:erlang.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:jido, :dispatch, :circuit, :melt],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      CircuitBreaker.install(adapter)
      CircuitBreaker.run(adapter, fn -> {:error, :fail} end)

      assert_receive {:telemetry, [:jido, :dispatch, :circuit, :melt], %{}, %{adapter: ^adapter}}

      :telemetry.detach(handler_id)
    end

    test "emits rejected event when circuit is open", %{adapter: adapter} do
      test_pid = self()
      handler_id = "test-rejected-#{:erlang.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:jido, :dispatch, :circuit, :rejected],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      # Allow 0 failures (blow on first)
      CircuitBreaker.install(adapter, strategy: {:standard, 0, 5_000}, refresh: 30_000)
      CircuitBreaker.run(adapter, fn -> {:error, :fail} end)

      CircuitBreaker.run(adapter, fn -> {:ok, :should_not_run} end)

      assert_receive {:telemetry, [:jido, :dispatch, :circuit, :rejected], %{},
                      %{adapter: ^adapter}}

      :telemetry.detach(handler_id)
    end

    test "emits reset event on reset", %{adapter: adapter} do
      test_pid = self()
      handler_id = "test-reset-#{:erlang.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:jido, :dispatch, :circuit, :reset],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      CircuitBreaker.install(adapter)
      CircuitBreaker.reset(adapter)

      assert_receive {:telemetry, [:jido, :dispatch, :circuit, :reset], %{}, %{adapter: ^adapter}}

      :telemetry.detach(handler_id)
    end
  end

  describe "circuit auto-reset after timeout" do
    test "circuit resets after refresh timeout", %{adapter: adapter} do
      # Allow 0 failures (blow on first)
      CircuitBreaker.install(adapter, strategy: {:standard, 0, 5_000}, refresh: 25)

      CircuitBreaker.run(adapter, fn -> {:error, :fail} end)

      assert CircuitBreaker.status(adapter) == :blown

      assert_eventually(fn -> CircuitBreaker.status(adapter) == :ok end)

      result = CircuitBreaker.run(adapter, fn -> {:ok, :success} end)
      assert result == {:ok, :success}
    end
  end

  defp assert_eventually(fun, timeout \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout
    assert eventually?(fun, deadline)
  end

  defp eventually?(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(10)
        eventually?(fun, deadline)
      end
    end
  end

  defp unique_instance do
    Module.concat(__MODULE__, "Instance#{System.unique_integer([:positive])}")
  end
end
