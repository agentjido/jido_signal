defmodule Jido.SignalTest do
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
end
