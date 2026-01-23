defmodule Jido.Signal.Serialization.ErrorClarityTest do
  use ExUnit.Case, async: true

  alias Jido.Signal.Serialization.{ErlangTermSerializer, JsonSerializer, MsgpackSerializer}

  describe "JsonSerializer error tagging" do
    test "json_decode_failed for invalid JSON" do
      invalid_json = "not-valid-json"

      assert {:error, {:json_decode_failed, message}} =
               JsonSerializer.deserialize(invalid_json)

      assert is_binary(message)
      assert message =~ "unexpected" or message =~ "invalid"
    end

    test "json_decode_failed for malformed JSON" do
      malformed = ~s({"key": "value")

      assert {:error, {:json_decode_failed, _}} =
               JsonSerializer.deserialize(malformed)
    end

    test "schema_validation_failed for invalid Signal" do
      # Has type, source, and id (signal_map? check) but invalid values
      invalid_signal = ~s({"type": "", "source": "", "id": "123"})

      assert {:error, {:schema_validation_failed, errors}} =
               JsonSerializer.deserialize(invalid_signal)

      assert is_map(errors)
      # Should have errors for both type and source being empty
      assert Map.has_key?(errors, "type") or Map.has_key?(errors, "source")
    end

    test "successful deserialization returns ok tuple" do
      valid_json = ~s({"type": "test", "source": "/s"})

      assert {:ok, _} = JsonSerializer.deserialize(valid_json)
    end
  end

  describe "MsgpackSerializer error tagging" do
    test "msgpack_decode_failed for invalid msgpack" do
      # Create intentionally invalid msgpack data
      invalid = <<0xFF, 0xFF, 0xFF>>

      assert {:error, {:msgpack_decode_failed, _}} =
               MsgpackSerializer.deserialize(invalid)
    end

    test "msgpack_decode_failed for truncated msgpack" do
      # Start of a valid msgpack map but truncated
      truncated = <<0x81>>

      assert {:error, {:msgpack_decode_failed, _}} =
               MsgpackSerializer.deserialize(truncated)
    end

    test "successful deserialization returns ok tuple" do
      {:ok, valid_msgpack} = MsgpackSerializer.serialize(%{"key" => "value"})

      assert {:ok, _} = MsgpackSerializer.deserialize(valid_msgpack)
    end
  end

  describe "ErlangTermSerializer error tagging" do
    test "erlang_term_decode_failed for invalid erlang term" do
      # Random bytes that don't form a valid Erlang term
      invalid = <<0x01, 0x02, 0x03>>

      assert {:error, {:erlang_term_decode_failed, _}} =
               ErlangTermSerializer.deserialize(invalid)
    end

    test "erlang_term_decode_failed for corrupted term" do
      # Partial Erlang term binary
      corrupted = <<131, 100>>

      assert {:error, {:erlang_term_decode_failed, _}} =
               ErlangTermSerializer.deserialize(corrupted)
    end

    test "successful deserialization returns ok tuple" do
      {:ok, valid_term} = ErlangTermSerializer.serialize(%{key: "value"})

      assert {:ok, _} = ErlangTermSerializer.deserialize(valid_term)
    end
  end

  describe "error messages are descriptive" do
    test "json errors include context" do
      {:error, {:json_decode_failed, msg}} =
        JsonSerializer.deserialize("{invalid")

      # Error message should be helpful
      assert String.length(msg) > 10
    end

    test "msgpack errors are not generic" do
      {:error, {tag, _msg}} =
        MsgpackSerializer.deserialize(<<0xFF, 0xFF>>)

      assert tag == :msgpack_decode_failed
    end

    test "erlang term errors are tagged correctly" do
      {:error, {tag, _msg}} =
        ErlangTermSerializer.deserialize(<<1, 2, 3>>)

      assert tag == :erlang_term_decode_failed
    end
  end

  describe "payload_too_large errors" do
    test "maintains specific error format" do
      large = String.duplicate("x", 11_000_000)

      assert {:error, {:payload_too_large, size, max}} =
               JsonSerializer.deserialize(large)

      assert size > max
    end
  end
end
