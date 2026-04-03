defmodule JidoTest.Signal.Dispatch.LoggerAdapterTest do
  use ExUnit.Case, async: false

  alias Jido.Signal
  alias Jido.Signal.Dispatch.LoggerAdapter

  describe "validate_opts/1" do
    test "defaults logger level to info" do
      assert {:ok, opts} = LoggerAdapter.validate_opts([])
      assert Keyword.get(opts, :level, :info) == :info
      assert Keyword.get(opts, :data_mode, :raw) == :raw
    end

    test "accepts explicit valid levels" do
      assert {:ok, opts} =
               LoggerAdapter.validate_opts(level: :warning, structured: true, data_mode: :preview)

      assert opts[:level] == :warning
      assert opts[:structured] == true
      assert opts[:data_mode] == :preview
    end

    test "rejects invalid levels" do
      assert {:error, message} = LoggerAdapter.validate_opts(level: :trace)
      assert message =~ "Invalid log level"
    end

    test "rejects invalid data_mode" do
      assert {:error, message} = LoggerAdapter.validate_opts(data_mode: :full)
      assert message =~ "Invalid data_mode"
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

    test "builds the legacy unstructured raw payload by default", %{signal: signal} do
      log_message = LoggerAdapter.build_log_message(signal)

      assert log_message ==
               "SIGNAL: test.signal from /test/source with data=#{inspect(signal.data)}"
    end

    test "builds structured output with raw data by default", %{signal: signal} do
      log_message = LoggerAdapter.build_log_message(signal, structured: true)

      assert log_message.event == "signal_dispatched"
      assert log_message.type == "test.signal"
      assert log_message.data == signal.data
      refute Map.has_key?(log_message, :data_preview)
    end

    test "builds an unstructured safe preview when opted in", %{signal: signal} do
      log_message = LoggerAdapter.build_log_message(signal, data_mode: :preview)

      assert log_message =~ "SIGNAL: test.signal from /test/source with data="
      assert log_message =~ String.duplicate("a", 50)
      assert log_message =~ "..."
    end

    test "builds structured output with raw data plus bounded preview when opted in", %{
      signal: signal
    } do
      log_message = LoggerAdapter.build_log_message(signal, structured: true, data_mode: :preview)

      assert log_message.event == "signal_dispatched"
      assert log_message.type == "test.signal"
      assert log_message.data == signal.data
      assert is_binary(log_message.data_preview)
      assert log_message.data_preview =~ String.duplicate("a", 50)
      assert log_message.data_preview =~ "..."
    end

    test "deliver/2 returns ok for unstructured logging", %{signal: signal} do
      assert :ok = LoggerAdapter.deliver(signal, level: :info)
    end

    test "deliver/2 returns ok for structured logging", %{signal: signal} do
      assert :ok = LoggerAdapter.deliver(signal, level: :info, structured: true)
    end

    test "deliver/2 returns ok for preview logging", %{signal: signal} do
      assert :ok =
               LoggerAdapter.deliver(signal,
                 level: :info,
                 structured: true,
                 data_mode: :preview
               )
    end
  end
end
