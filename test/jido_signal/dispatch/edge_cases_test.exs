defmodule Jido.Signal.DispatchEdgeCasesTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Dispatch

  describe "concurrent dispatches" do
    test "handles 50 dispatches to same PID" do
      {:ok, signal} = Signal.new("test.concurrent", %{})
      test_pid = self()

      configs =
        Enum.map(1..50, fn _i ->
          {:pid, [target: test_pid]}
        end)

      assert :ok = Dispatch.dispatch_batch(signal, configs)

      for _i <- 1..50 do
        assert_received {:signal, %Signal{type: "test.concurrent"}}
      end
    end
  end

  describe "empty config list" do
    test "returns :ok with empty configs" do
      {:ok, signal} = Signal.new("test.empty", %{})
      assert :ok = Dispatch.dispatch_batch(signal, [])
    end
  end

  describe "validate_opts" do
    test "accepts valid configs" do
      {:ok, valid_configs} = Dispatch.validate_opts([{:noop, []}])
      assert is_list(valid_configs)
    end

    test "rejects invalid adapter" do
      result = Dispatch.validate_opts([{:invalid_adapter, []}])
      assert {:error, _errors} = result
    end
  end

  describe "signal variations" do
    test "handles signals with large data payloads" do
      large_data = %{content: String.duplicate("x", 10_000)}
      {:ok, signal} = Signal.new("test.large", large_data)
      test_pid = self()

      config = {:pid, [target: test_pid]}

      assert :ok = Dispatch.dispatch_batch(signal, [config])
      assert_received {:signal, %Signal{data: ^large_data}}
    end

    test "handles signals with nil data" do
      {:ok, signal} = Signal.new("test.nil", nil)
      test_pid = self()

      config = {:pid, [target: test_pid]}

      assert :ok = Dispatch.dispatch_batch(signal, [config])
      assert_received {:signal, %Signal{data: nil}}
    end

    test "handles signals with complex nested data" do
      data = %{
        level1: %{
          level2: %{
            level3: [1, 2, %{key: "value"}]
          }
        }
      }

      {:ok, signal} = Signal.new("test.nested", data)
      test_pid = self()

      config = {:pid, [target: test_pid]}

      assert :ok = Dispatch.dispatch_batch(signal, [config])
      assert_received {:signal, %Signal{data: ^data}}
    end
  end

  describe "concurrency edge cases" do
    test "handles max_concurrency: 1" do
      {:ok, signal} = Signal.new("test.serial", %{})
      test_pid = self()

      configs =
        Enum.map(1..10, fn _i ->
          {:pid, [target: test_pid]}
        end)

      assert :ok = Dispatch.dispatch_batch(signal, configs, max_concurrency: 1)

      for _i <- 1..10 do
        assert_received {:signal, %Signal{type: "test.serial"}}
      end
    end

    test "handles max_concurrency larger than config count" do
      {:ok, signal} = Signal.new("test.over_concurrent", %{})
      test_pid = self()

      configs =
        Enum.map(1..3, fn _i ->
          {:pid, [target: test_pid]}
        end)

      assert :ok = Dispatch.dispatch_batch(signal, configs, max_concurrency: 100)

      for _i <- 1..3 do
        assert_received {:signal, %Signal{type: "test.over_concurrent"}}
      end
    end
  end

  describe "batch size edge cases" do
    test "handles batch_size: 1" do
      {:ok, signal} = Signal.new("test.batch_one", %{})
      test_pid = self()

      configs =
        Enum.map(1..5, fn _i ->
          {:pid, [target: test_pid]}
        end)

      assert :ok = Dispatch.dispatch_batch(signal, configs, batch_size: 1)

      for _i <- 1..5 do
        assert_received {:signal, %Signal{type: "test.batch_one"}}
      end
    end

    test "handles very large batch_size" do
      {:ok, signal} = Signal.new("test.large_batch", %{})
      test_pid = self()

      configs =
        Enum.map(1..10, fn _i ->
          {:pid, [target: test_pid]}
        end)

      assert :ok = Dispatch.dispatch_batch(signal, configs, batch_size: 10_000)

      for _i <- 1..10 do
        assert_received {:signal, %Signal{type: "test.large_batch"}}
      end
    end
  end

  describe "invalid configurations" do
    test "batch dispatch reports errors for invalid adapters" do
      {:ok, signal} = Signal.new("test.invalid", %{})

      configs = [
        {:nonexistent_adapter, []},
        {:another_invalid, []}
      ]

      result = Dispatch.dispatch_batch(signal, configs)
      assert {:error, errors} = result
      assert length(errors) == 2
    end

    @tag :capture_log
    test "mixed valid and invalid configs" do
      {:ok, signal} = Signal.new("test.mixed_valid", %{})

      configs = [
        {:noop, []},
        {:invalid_adapter, []},
        {:logger, [level: :debug]}
      ]

      result = Dispatch.dispatch_batch(signal, configs)
      assert {:error, errors} = result
      assert length(errors) == 1
    end
  end

  describe "mixed adapter types" do
    @tag :capture_log
    test "handles different adapter types in same batch" do
      {:ok, signal} = Signal.new("test.mixed", %{})
      test_pid = self()

      configs = [
        {:pid, [target: test_pid]},
        {:noop, []},
        {:pid, [target: test_pid]},
        {:noop, []}
      ]

      assert :ok = Dispatch.dispatch_batch(signal, configs)

      assert_received {:signal, %Signal{type: "test.mixed"}}
      assert_received {:signal, %Signal{type: "test.mixed"}}
    end
  end

  describe "stress scenarios" do
    test "handles rapid batch dispatches" do
      test_pid = self()

      for _batch <- 1..10 do
        {:ok, signal} = Signal.new("test.rapid", %{})

        configs =
          Enum.map(1..10, fn _i ->
            {:pid, [target: test_pid]}
          end)

        assert :ok = Dispatch.dispatch_batch(signal, configs)
      end

      for _i <- 1..100 do
        assert_received {:signal, %Signal{type: "test.rapid"}}
      end
    end
  end

  describe "configuration validation edge cases" do
    test "empty options list is valid" do
      assert {:ok, _} = Dispatch.validate_opts([])
    end

    test "nil adapter with empty opts" do
      result = Dispatch.validate_opts([{nil, []}])
      assert {:ok, _} = result
    end

    test "multiple noop adapters" do
      configs = Enum.map(1..100, fn _i -> {:noop, []} end)
      assert {:ok, validated} = Dispatch.validate_opts(configs)
      assert length(validated) == 100
    end
  end

  describe "signal field variations" do
    test "signal with custom source" do
      {:ok, signal} = Signal.new("test.source", %{}, source: "/custom/source")
      test_pid = self()

      assert :ok = Dispatch.dispatch_batch(signal, [{:pid, [target: test_pid]}])
      assert_received {:signal, %Signal{source: "/custom/source"}}
    end

    test "signal with subject field" do
      {:ok, signal} = Signal.new("test.subject", %{}, subject: "user.123")
      test_pid = self()

      assert :ok = Dispatch.dispatch_batch(signal, [{:pid, [target: test_pid]}])
      assert_received {:signal, %Signal{subject: "user.123"}}
    end

    test "signal with extensions" do
      {:ok, signal} = Signal.new("test.ext", %{}, extensions: %{custom: "value"})
      test_pid = self()

      assert :ok = Dispatch.dispatch_batch(signal, [{:pid, [target: test_pid]}])
      assert_received {:signal, %Signal{extensions: %{custom: "value"}}}
    end
  end

  describe "adapter option variations" do
    test "pid adapter async mode is best-effort for dead process targets" do
      dead_pid = spawn(fn -> :ok end)
      Process.sleep(10)

      {:ok, signal} = Signal.new("test.dead_pid", %{})

      result = Dispatch.dispatch_batch(signal, [{:pid, [target: dead_pid]}])
      assert :ok = result
    end

    test "named adapter with non-existent name returns error" do
      {:ok, signal} = Signal.new("test.nonexistent_name", %{})

      result = Dispatch.dispatch_batch(signal, [{:named, [target: :nonexistent_process]}])
      assert {:error, [{0, _}]} = result
    end
  end
end
