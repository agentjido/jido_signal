defmodule Jido.Signal.Serialization.PayloadLimitTest do
  use ExUnit.Case, async: false

  alias Jido.Signal.Serialization.{
    Config,
    ErlangTermSerializer,
    JsonSerializer,
    MsgpackSerializer
  }

  setup do
    # Save original config
    original = Application.get_env(:jido, :max_payload_bytes)

    on_exit(fn ->
      # Restore original config
      if original do
        Application.put_env(:jido, :max_payload_bytes, original)
      else
        Application.delete_env(:jido, :max_payload_bytes)
      end
    end)

    :ok
  end

  describe "config" do
    test "max_payload_bytes/0 returns default" do
      Application.delete_env(:jido, :max_payload_bytes)
      assert Config.max_payload_bytes() == 10_000_000
    end

    test "max_payload_bytes/0 returns configured value" do
      Application.put_env(:jido, :max_payload_bytes, 5_000_000)
      assert Config.max_payload_bytes() == 5_000_000
    end
  end

  describe "JsonSerializer payload limits" do
    test "rejects payloads exceeding max size" do
      large_binary = String.duplicate("x", 11_000_000)

      assert {:error, {:payload_too_large, size, max}} = JsonSerializer.deserialize(large_binary)
      assert size > max
      assert max == 10_000_000
    end

    test "accepts payloads within max size" do
      small_json = ~s({"type": "test", "source": "/test"})

      # Should succeed (or fail for other reasons, but not size)
      case JsonSerializer.deserialize(small_json) do
        {:ok, _} -> assert true
        {:error, reason} -> refute match?({:payload_too_large, _, _}, reason)
      end
    end
  end

  describe "MsgpackSerializer payload limits" do
    test "rejects payloads exceeding max size" do
      large_binary = String.duplicate("x", 11_000_000)

      assert {:error, {:payload_too_large, size, max}} =
               MsgpackSerializer.deserialize(large_binary)

      assert size > max
    end

    test "accepts payloads within max size" do
      {:ok, small_msgpack} = MsgpackSerializer.serialize(%{"test" => "data"})

      # Should succeed
      assert {:ok, _} = MsgpackSerializer.deserialize(small_msgpack)
    end
  end

  describe "ErlangTermSerializer payload limits" do
    test "rejects payloads exceeding max size" do
      large_binary = String.duplicate("x", 11_000_000)

      assert {:error, {:payload_too_large, size, max}} =
               ErlangTermSerializer.deserialize(large_binary)

      assert size > max
    end

    test "accepts payloads within max size" do
      {:ok, small_term} = ErlangTermSerializer.serialize(%{test: "data"})

      # Should succeed
      assert {:ok, _} = ErlangTermSerializer.deserialize(small_term)
    end
  end

  describe "custom payload limits" do
    test "respects custom configuration" do
      Application.put_env(:jido, :max_payload_bytes, 100)

      medium_json = String.duplicate("x", 200)

      assert {:error, {:payload_too_large, 200, 100}} = JsonSerializer.deserialize(medium_json)
    end
  end
end
