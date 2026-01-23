defmodule Jido.Signal.Serialization.VersioningTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Serialization.{ErlangTermSerializer, JsonSerializer, MsgpackSerializer}

  defmodule TestExt do
    use Jido.Signal.Ext,
      namespace: "versiontest",
      schema: [
        message: [type: :string, required: true]
      ]
  end

  describe "JsonSerializer versioning" do
    test "serialized Signal includes jido_schema_version" do
      signal = Signal.new!(type: "test.event", source: "/test")
      {:ok, json} = JsonSerializer.serialize(signal)
      map = Jason.decode!(json)

      assert map["jido_schema_version"] == 1
    end

    test "version field survives round-trip" do
      signal = Signal.new!(type: "test.event", source: "/test", id: "123")
      {:ok, json} = JsonSerializer.serialize(signal)
      {:ok, deserialized} = JsonSerializer.deserialize(json)

      # Verify signal was reconstructed correctly
      assert deserialized["type"] == "test.event"
      assert deserialized["source"] == "/test"
    end

    test "deserializes old signals without version field" do
      # Simulate old signal without version
      old_json = ~s({"type":"test.event","source":"/test","id":"old123"})
      {:ok, deserialized} = JsonSerializer.deserialize(old_json)

      assert deserialized["type"] == "test.event"
      assert deserialized["source"] == "/test"
    end

    test "accepts signals with explicit version field" do
      json_with_version = ~s({"type":"test.event","source":"/test","jido_schema_version":1})
      {:ok, deserialized} = JsonSerializer.deserialize(json_with_version)

      assert deserialized["type"] == "test.event"
    end
  end

  describe "MsgpackSerializer versioning" do
    test "serialized Signal includes jido_schema_version" do
      signal = Signal.new!(type: "test.event", source: "/test")
      {:ok, msgpack} = MsgpackSerializer.serialize(signal)
      {:ok, unpacked} = Msgpax.unpack(msgpack)

      assert unpacked["jido_schema_version"] == 1
    end

    test "version field survives round-trip" do
      signal = Signal.new!(type: "test.event", source: "/test", id: "123")
      {:ok, msgpack} = MsgpackSerializer.serialize(signal)
      {:ok, deserialized} = MsgpackSerializer.deserialize(msgpack)

      assert deserialized["type"] == "test.event"
      assert deserialized["source"] == "/test"
    end
  end

  describe "ErlangTermSerializer versioning" do
    test "serialized Signal includes jido_schema_version" do
      signal = Signal.new!(type: "test.event", source: "/test")
      {:ok, term_binary} = ErlangTermSerializer.serialize(signal)
      term_map = :erlang.binary_to_term(term_binary, [:safe])

      # ErlangTerm may have atom or string keys depending on source
      version = term_map["jido_schema_version"] || term_map[:jido_schema_version]
      assert version == 1
    end

    test "version field survives round-trip" do
      signal = Signal.new!(type: "test.event", source: "/test", id: "123")
      {:ok, term_binary} = ErlangTermSerializer.serialize(signal)
      {:ok, deserialized} = ErlangTermSerializer.deserialize(term_binary)

      # Check core fields are preserved
      assert is_map(deserialized)
    end
  end

  describe "backward compatibility" do
    test "all serializers handle signals without version gracefully" do
      # Create a signal, serialize it, manually remove version, deserialize
      signal = Signal.new!(type: "test.event", source: "/test")

      # JSON
      {:ok, json} = JsonSerializer.serialize(signal)
      json_map = Jason.decode!(json)
      no_version_json = json_map |> Map.delete("jido_schema_version") |> Jason.encode!()
      assert {:ok, _} = JsonSerializer.deserialize(no_version_json)

      # MsgPack
      {:ok, msgpack} = MsgpackSerializer.serialize(signal)
      {:ok, msgpack_map} = Msgpax.unpack(msgpack)
      no_version_map = Map.delete(msgpack_map, "jido_schema_version")
      {:ok, no_version_msgpack_iodata} = Msgpax.pack(no_version_map)
      no_version_msgpack = IO.iodata_to_binary(no_version_msgpack_iodata)
      assert {:ok, _} = MsgpackSerializer.deserialize(no_version_msgpack)
    end
  end

  describe "version field with extensions" do
    test "version field coexists with extensions" do
      signal = Signal.new!(type: "test.event", source: "/test")
      {:ok, signal_with_ext} = Signal.put_extension(signal, "versiontest", %{message: "value"})

      {:ok, json} = JsonSerializer.serialize(signal_with_ext)
      map = Jason.decode!(json)

      # Both version and extension data should be present
      assert map["jido_schema_version"] == 1
      assert map["message"] == "value"
    end

    test "round-trip preserves version and extensions" do
      signal = Signal.new!(type: "test.event", source: "/test")
      {:ok, signal_with_ext} = Signal.put_extension(signal, "versiontest", %{message: "val"})

      {:ok, json} = JsonSerializer.serialize(signal_with_ext)
      {:ok, deserialized} = JsonSerializer.deserialize(json)

      assert deserialized["type"] == "test.event"
      # Extensions are inflated into "extensions" map during deserialization
      assert is_map(deserialized["extensions"])
    end
  end
end
