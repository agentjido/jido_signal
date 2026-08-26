defmodule Jido.Signal.CoreTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.ID

  describe "new/1" do
    test "generates a UUID7 and CloudEvents 1.0 specversion" do
      assert {:ok, signal} = Signal.new(type: "example.event", source: "/example")

      assert ID.valid?(signal.id)
      assert signal.specversion == "1.0"
      assert signal.source == "/example"
    end

    test "requires an explicit source" do
      assert {:error, error} = Signal.new(type: "example.event")
      assert error =~ "source"
    end

    test "does not invent time or data content type" do
      assert {:ok, signal} =
               Signal.new(type: "example.event", source: "/example", data: %{value: 1})

      assert signal.time == nil
      assert signal.datacontenttype == nil
    end

    test "accepts an external identifier" do
      assert {:ok, signal} =
               Signal.new(type: "example.event", source: "/example", id: "external-id")

      assert signal.id == "external-id"
    end

    test "validates event time and data schema" do
      assert {:ok, signal} =
               Signal.new(
                 type: "example.event",
                 source: "/example",
                 time: "2026-08-26T12:00:00Z",
                 dataschema: "https://example.com/schemas/event"
               )

      assert signal.time == "2026-08-26T12:00:00Z"

      assert {:error, error} =
               Signal.new(type: "example.event", source: "/example", time: "yesterday")

      assert error =~ "RFC 3339"

      assert {:error, error} =
               Signal.new(type: "example.event", source: "/example", dataschema: "/relative")

      assert error =~ "absolute URI"
    end
  end

  describe "new/3" do
    test "creates a Signal with explicit type and data" do
      assert {:ok, signal} =
               Signal.new("user.created", %{user_id: "123"}, source: "/accounts")

      assert signal.type == "user.created"
      assert signal.data == %{user_id: "123"}
      assert signal.source == "/accounts"
    end

    test "requires source in the attribute set" do
      assert {:error, error} = Signal.new("user.created", %{user_id: "123"})
      assert error =~ "source"
    end

    test "rejects type and data overrides" do
      assert {:error, error} = Signal.new("test.event", %{}, type: "other.event")
      assert error =~ "attribute :type"

      assert {:error, error} = Signal.new("test.event", %{}, %{"data" => "other"})
      assert error =~ "attribute \"data\""
    end

    test "accepts all data values, including an empty string" do
      for value <- [nil, "", "text", 1, true, [1, 2], %{value: 1}] do
        assert {:ok, signal} = Signal.new("test.event", value, source: "/test")
        assert signal.data == value
      end
    end
  end

  describe "from_map/1" do
    test "parses a complete CloudEvents 1.0 envelope" do
      map = %{
        "specversion" => "1.0",
        "id" => "123",
        "source" => "/example",
        "type" => "example.event",
        "subject" => "record/123",
        "time" => "2026-08-26T12:00:00Z",
        "datacontenttype" => "application/json",
        "dataschema" => "https://example.com/schema",
        "data" => %{"value" => 1}
      }

      assert {:ok, signal} = Signal.from_map(map)
      assert signal.id == "123"
      assert signal.specversion == "1.0"
      assert signal.data == %{"value" => 1}
    end

    test "does not generate missing required wire attributes" do
      assert {:error, error} =
               Signal.from_map(%{"specversion" => "1.0", "source" => "/example"})

      assert error =~ "id"
      assert error =~ "type"
    end

    test "normalizes the legacy document patch value" do
      assert {:ok, signal} =
               Signal.from_map(%{
                 "specversion" => "1.0.2",
                 "id" => "123",
                 "source" => "/example",
                 "type" => "example.event"
               })

      assert signal.specversion == "1.0"
      assert Signal.to_map(signal)["specversion"] == "1.0"
    end

    test "rejects unsupported spec versions" do
      assert {:error, error} =
               Signal.from_map(%{
                 "specversion" => "0.3",
                 "id" => "123",
                 "source" => "/example",
                 "type" => "example.event"
               })

      assert error =~ "specversion"
    end
  end

  describe "CloudEvents extension context attributes" do
    setup do
      signal = Signal.new!("test.event", %{}, source: "/test")
      %{signal: signal}
    end

    test "stores and emits flat scalar attributes", %{signal: signal} do
      assert {:ok, signal} = Signal.put_context(signal, "tenantid", "tenant-123")
      assert {:ok, signal} = Signal.put_context(signal, :attempt, 2)
      assert {:ok, signal} = Signal.put_context(signal, "sampled", true)

      assert Signal.get_context(signal, "tenantid") == "tenant-123"
      assert Enum.sort(Signal.list_context(signal)) == ["attempt", "sampled", "tenantid"]

      wire = Signal.to_map(signal)
      assert wire["tenantid"] == "tenant-123"
      assert wire["attempt"] == 2
      refute Map.has_key?(wire, "extensions")
      refute Map.has_key?(wire, "jido_schema_version")
    end

    test "reads unknown top-level attributes as context", %{signal: signal} do
      wire = Signal.to_map(signal) |> Map.put("tenantid", "tenant-123")

      assert {:ok, decoded} = Signal.from_map(wire)
      assert decoded.extensions == %{"tenantid" => "tenant-123"}
    end

    test "rejects names outside the CloudEvents rules", %{signal: signal} do
      assert {:error, error} = Signal.put_context(signal, "trace_id", "abc")
      assert error =~ "extension name"

      assert {:error, error} = Signal.put_context(signal, "Type", "abc")
      assert error =~ "extension name"

      assert {:error, error} = Signal.put_context(signal, "data", "abc")
      assert error =~ "conflicts"
    end

    test "rejects compound values", %{signal: signal} do
      assert {:error, error} = Signal.put_context(signal, "routing", %{target: "worker"})
      assert error =~ "extension values"
    end

    test "deletes a context attribute", %{signal: signal} do
      assert {:ok, signal} = Signal.put_context(signal, "tenantid", "tenant-123")
      signal = Signal.delete_context(signal, "tenantid")
      assert Signal.get_context(signal, "tenantid") == nil
    end
  end
end
