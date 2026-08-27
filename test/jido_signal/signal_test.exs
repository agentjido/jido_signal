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

    test "rejects invalid text, URI, and media type values" do
      invalid_utf8 = <<255>>
      base = [type: "example.event", source: "/example"]

      for attributes <- [
            Keyword.put(base, :id, invalid_utf8),
            Keyword.put(base, :source, invalid_utf8),
            Keyword.put(base, :type, invalid_utf8),
            Keyword.put(base, :subject, invalid_utf8),
            Keyword.put(base, :time, invalid_utf8),
            Keyword.put(base, :datacontenttype, invalid_utf8),
            Keyword.put(base, :dataschema, invalid_utf8)
          ] do
        assert {:error, _message} = Signal.new(attributes)
      end

      assert {:error, _message} = Signal.new(Keyword.put(base, :source, "/bad%ZZ"))
      assert {:error, _message} = Signal.new(Keyword.put(base, :source, "/café"))

      assert {:error, _message} =
               Signal.new(Keyword.put(base, :dataschema, "https://example.com/bad%ZZ"))

      assert {:error, _message} =
               Signal.new(Keyword.put(base, :datacontenttype, "not a media type"))

      assert {:error, _message} =
               Signal.new(Keyword.put(base, :datacontenttype, "text/plain\r\nx-header: value"))
    end

    test "accepts valid media type parameters" do
      assert {:ok, signal} =
               Signal.new(
                 type: "example.event",
                 source: "/example",
                 datacontenttype: "application/json; charset=utf-8"
               )

      assert signal.datacontenttype == "application/json; charset=utf-8"

      assert {:ok, _signal} =
               Signal.new(
                 type: "example.event",
                 source: "/example",
                 datacontenttype: ~s(application/json; profile="https://example.com/profile")
               )
    end

    test "keeps validator callbacks total for direct use" do
      assert {:error, _message} = Signal.validate_uri_reference(:invalid, [])
      assert {:error, _message} = Signal.validate_uri_reference("http://[", [])
      assert {:error, _message} = Signal.validate_absolute_uri(:invalid, [])
      assert {:error, _message} = Signal.validate_rfc3339(:invalid, [])
      assert {:error, _message} = Signal.validate_utf8_string(:invalid, [])
      assert {:error, _message} = Signal.validate_media_type(:invalid, [])
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
      assert error =~ "attribute \"type\""

      assert {:error, error} = Signal.new("test.event", %{}, %{"data" => "other"})
      assert error =~ "attribute \"data\""
    end

    test "accepts all data values, including an empty string" do
      for value <- [nil, "", "text", 1, true, [1, 2], %{value: 1}] do
        assert {:ok, signal} = Signal.new("test.event", value, source: "/test")
        assert signal.data == value
      end
    end

    test "rejects malformed option containers without raising" do
      assert {:error, _message} = Signal.new([:bad])
      assert {:error, _message} = Signal.new("test.event", %{}, [:bad])
      assert {:error, _message} = Signal.new(%{{:tuple, :key} => 1})
    end
  end
end
