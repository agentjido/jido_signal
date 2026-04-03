defmodule JidoTest.Signal.Dispatch.LoggerAdapterTest do
  use ExUnit.Case, async: false

  alias Jido.Signal
  alias Jido.Signal.Dispatch.LoggerAdapter

  describe "validate_opts/1" do
    test "defaults logger level to debug" do
      assert {:ok, opts} = LoggerAdapter.validate_opts([])
      assert Keyword.get(opts, :level, :debug) == :debug
    end

    test "accepts explicit valid levels" do
      assert {:ok, opts} = LoggerAdapter.validate_opts(level: :warning, structured: true)
      assert opts[:level] == :warning
      assert opts[:structured] == true
    end

    test "rejects invalid levels" do
      assert {:error, message} = LoggerAdapter.validate_opts(level: :trace)
      assert message =~ "Invalid log level"
    end
  end

  describe "build_log_message/2" do
    setup do
      {:ok, signal} =
        Signal.new(%{
          type: "test.signal",
          source: "/test/source",
          data: %{
            message: String.duplicate("a", 260),
            nested: %{items: Enum.to_list(1..5)}
          }
        })

      {:ok, signal: signal}
    end

    test "builds an unstructured safe preview", %{signal: signal} do
      log_message = LoggerAdapter.build_log_message(signal, level: :debug)

      assert log_message =~ "SIGNAL: test.signal from /test/source with data="
      assert log_message =~ String.duplicate("a", 50)
      assert log_message =~ "..."
    end

    test "builds structured output without dumping raw payloads", %{signal: signal} do
      log_message = LoggerAdapter.build_log_message(signal, level: :debug, structured: true)

      assert log_message.event == "signal_dispatched"
      assert log_message.type == "test.signal"
      assert is_binary(log_message.data)
      assert log_message.data =~ String.duplicate("a", 50)
      assert log_message.data =~ "..."
    end

    test "deliver/2 returns ok for unstructured logging", %{signal: signal} do
      assert :ok = LoggerAdapter.deliver(signal, level: :debug)
    end

    test "deliver/2 returns ok for structured logging", %{signal: signal} do
      assert :ok = LoggerAdapter.deliver(signal, level: :debug, structured: true)
    end
  end
end
