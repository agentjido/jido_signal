defmodule Jido.Signal.CatalogTest do
  use JidoSignalTest.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Catalog
  alias Jido.Signal.Error.InvalidInputError

  defmodule MessageReceived do
    use Jido.Signal,
      type: "example.message.received",
      default_source: "/messages",
      dataschema: "https://example.com/message/v1",
      schema:
        Zoi.object(%{"text" => Zoi.string(), "room" => Zoi.string()}, unrecognized_keys: :error)
  end

  defmodule MessageReceivedV2 do
    use Jido.Signal,
      type: "example.message.received",
      default_source: "/messages",
      dataschema: "https://example.com/message/v2",
      schema: Zoi.object(%{"body" => Zoi.string()}, unrecognized_keys: :error)
  end

  defmodule ConflictingMessage do
    use Jido.Signal,
      type: "example.message.received",
      dataschema: "https://example.com/message/v1"
  end

  defmodule TemperatureMeasured do
    use Jido.Signal,
      type: "example.sensor.temperature",
      default_source: "/sensors",
      schema:
        Zoi.object(%{
          "celsius" => Zoi.number(),
          "unit" => Zoi.string() |> Zoi.default("C")
        })
  end

  defmodule StrictAtomKeys do
    use Jido.Signal,
      type: "example.atom.strict",
      default_source: "/test",
      schema: Zoi.object(%{value: Zoi.integer()})
  end

  defmodule CoercedKeys do
    use Jido.Signal,
      type: "example.keys.coerced",
      default_source: "/test",
      schema:
        Zoi.object(%{"nested" => Zoi.object(%{value: Zoi.integer()}, coerce: true)}, coerce: true)
  end

  defmodule BinaryData do
    use Jido.Signal,
      type: "example.binary",
      default_source: "/test",
      schema: Zoi.string()
  end

  defmodule IncompleteDefinition do
    def __signal_definition__, do: %{}
    def type, do: "incomplete.definition"
  end

  defmodule FaultyValidator do
    use Jido.Signal,
      type: "example.faulty",
      default_source: "/test",
      schema: Zoi.any() |> Zoi.refine({Jido.Signal.CatalogTest, :faulty_validator, []})
  end

  setup do
    catalog = Catalog.new!([MessageReceived, MessageReceivedV2, TemperatureMeasured])
    %{catalog: catalog}
  end

  describe "new/1" do
    test "builds an empty catalog and rejects unknown types" do
      assert {:ok, catalog} = Catalog.new([])
      assert_error(Catalog.validate(catalog, message()), :unknown_type)
    end

    test "rejects invalid collections and explicit definitions" do
      for value <- [
            nil,
            %{},
            "module",
            [MessageReceived | :tail],
            [String],
            [IncompleteDefinition],
            ["example.message.received"],
            [:unloaded_module]
          ] do
        error = assert_error(Catalog.new(value), :invalid_definitions)
        assert is_list(error.details.reason)
      end
    end

    test "rejects all duplicate pairs, including a repeated module" do
      for {first, other} <- [
            {MessageReceived, MessageReceived},
            {MessageReceived, ConflictingMessage},
            {TemperatureMeasured, TemperatureMeasured}
          ] do
        error = assert_error(Catalog.new([first, other]), :duplicate_definition)
        assert error.details.type == first.type()
        assert error.details.dataschema == first.dataschema()
        assert error.details.definitions == [first, other]
      end

      assert_raise InvalidInputError, fn -> Catalog.new!([MessageReceived, MessageReceived]) end
    end
  end

  describe "validate/2" do
    test "keeps identity and context during domain revalidation", %{catalog: catalog} do
      signal = message()
      assert {:ok, ^signal} = Catalog.validate(catalog, signal)
      assert {:ok, ^signal} = Catalog.validate(catalog, signal)
    end

    test "checks an unrelated family and applies its data defaults", %{catalog: catalog} do
      signal = Signal.new!(TemperatureMeasured.type(), %{"celsius" => 21.5}, source: "/remote")
      assert {:ok, validated} = Catalog.validate(catalog, signal)
      assert validated == %{signal | data: %{"celsius" => 21.5, "unit" => "C"}}
    end

    test "selects each schema version exactly", %{catalog: catalog} do
      signal = MessageReceivedV2.new!(%{"body" => "hello"})
      assert {:ok, ^signal} = Catalog.validate(catalog, signal)

      assert_error(
        Catalog.validate(catalog, %{message() | dataschema: signal.dataschema}),
        :invalid_data
      )
    end

    test "reports unknown types and schema identities", %{catalog: catalog} do
      signal = message()

      error =
        assert_error(Catalog.validate(catalog, %{signal | type: "unknown.type"}), :unknown_type)

      assert error.details.type == "unknown.type"

      for schema <- [nil, "https://example.com/message/v3"] do
        error =
          assert_error(
            Catalog.validate(catalog, %{signal | dataschema: schema}),
            :unknown_dataschema
          )

        assert error.details.dataschema == schema
      end

      sensor = TemperatureMeasured.new!(%{"celsius" => 1})

      assert_error(
        Catalog.validate(catalog, %{sensor | dataschema: MessageReceived.dataschema()}),
        :unknown_dataschema
      )
    end

    test "does not treat a type path as a wildcard" do
      catalog = Catalog.new!([TemperatureMeasured])
      signal = Signal.new!("example.sensor.*", %{"celsius" => 1}, source: "/test")
      assert_error(Catalog.validate(catalog, signal), :unknown_type)
    end

    test "retains domain errors and the chosen definition", %{catalog: catalog} do
      error =
        assert_error(
          Catalog.validate(catalog, %{message() | data: %{"text" => 10}}),
          :invalid_data
        )

      assert error.details.definition == MessageReceived
      assert [%Zoi.Error{} | _] = error.details.reason
    end

    test "rejects invalid core attributes before lookup", %{catalog: catalog} do
      for {key, value} <- [
            id: nil,
            source: "bad source",
            time: "bad",
            specversion: "2.0",
            dataschema: "/relative",
            data_present?: :invalid,
            data_base64?: :invalid
          ] do
        assert_error(Catalog.validate(catalog, Map.put(message(), key, value)), :invalid_envelope)
      end
    end

    test "validates and normalizes transport context", %{catalog: catalog} do
      signal = %{message() | extensions: %{traceparent: "valid opaque text", attempt: 2}}
      assert {:ok, validated} = Catalog.validate(catalog, signal)
      assert validated.extensions == %{"traceparent" => "valid opaque text", "attempt" => 2}

      for context <- [
            %{"invalid" => %{}},
            %{"badName" => "x"},
            %{"attempt" => nil},
            %{"attempt" => 2_147_483_648},
            %{"traceparent" => "b", traceparent: "a"}
          ] do
        assert_error(
          Catalog.validate(catalog, %{signal | extensions: context}),
          :invalid_envelope
        )
      end
    end

    test "rejects values that are not Signals", %{catalog: catalog} do
      for value <- [nil, [], Signal.to_map(message()), %{type: "unknown"}] do
        assert_error(Catalog.validate(catalog, value), :invalid_input)
      end

      assert_error(Catalog.validate(nil, message()), :invalid_input)
    end

    test "constructor options cannot change definition identity or validated data", %{
      catalog: catalog
    } do
      signal =
        MessageReceived.new!(%{"text" => "hello", "room" => "one"},
          type: TemperatureMeasured.type(),
          data: %{"celsius" => 1},
          dataschema: MessageReceivedV2.dataschema()
        )

      assert signal.type == MessageReceived.type()
      assert signal.dataschema == MessageReceived.dataschema()
      assert {:ok, ^signal} = Catalog.validate(catalog, signal)

      sensor =
        TemperatureMeasured.new!(%{"celsius" => 1}, dataschema: MessageReceived.dataschema())

      assert sensor.dataschema == nil
      assert {:ok, ^sensor} = Catalog.validate(catalog, sensor)
    end

    test "contains schema callback faults in structured errors" do
      catalog = Catalog.new!([FaultyValidator])

      for data <- [:raise, :throw, :exit] do
        signal = Signal.new!(FaultyValidator.type(), data, source: "/test")
        error = assert_error(Catalog.validate(catalog, signal), :validation_failed)
        assert error.details.definition == FaultyValidator
        assert error.details.reason != nil
      end
    end
  end

  describe "decode/3" do
    test "round trips JSON and preserves all supplied metadata", %{catalog: catalog} do
      signal = message()
      assert {:ok, json} = Signal.serialize(signal)
      assert {:ok, ^signal} = Catalog.decode(catalog, json)
      assert {:ok, ^signal} = Catalog.decode(catalog, Signal.to_map(signal))
      assert {:ok, decoded} = Catalog.decode(catalog, json)
      assert {:ok, ^json} = Signal.serialize(decoded)
    end

    test "revalidates JSON data after generic envelope decode", %{catalog: catalog} do
      wire = message() |> Signal.to_map() |> Map.put("data", %{"text" => false, "room" => "one"})
      assert {:ok, _signal} = Signal.from_map(wire)
      assert_error(Catalog.decode(catalog, Jason.encode!(wire)), :invalid_data)
    end

    test "does not create atoms from runtime types, schema identities, or keys", %{
      catalog: catalog
    } do
      suffix = Integer.to_string(System.unique_integer([:positive]))
      names = ["runtime.type." <> suffix, "urn:runtime:schema:" <> suffix, "key" <> suffix]
      [type, schema, key] = names

      for name <- names do
        assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      end

      wire = message() |> Signal.to_map() |> Map.put(key, true)
      assert {:ok, signal} = Catalog.decode(catalog, Jason.encode!(wire))
      assert signal.extensions[key] == true

      unknown = wire |> Map.put("type", type) |> Map.put("dataschema", schema)
      assert_error(Catalog.decode(catalog, Jason.encode!(unknown)), :unknown_type)
      assert_error(Catalog.decode(catalog, put_in(wire, ["data", key], "unknown")), :invalid_data)

      for name <- names do
        assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      end
    end

    test "uses existing envelope key normalization", %{catalog: catalog} do
      wire = %{
        id: "external-id",
        specversion: "1.0.2",
        source: "/remote",
        type: TemperatureMeasured.type(),
        data: %{"celsius" => 10}
      }

      assert {:ok, decoded} = Catalog.decode(catalog, wire)
      assert decoded.id == "external-id"
      assert decoded.specversion == "1.0"
      assert decoded.data == %{"celsius" => 10, "unit" => "C"}
      assert_error(Catalog.decode(catalog, Map.put(wire, "id", "other")), :decode_failed)
    end

    test "retains schema-owned data key and value rules" do
      catalog = Catalog.new!([StrictAtomKeys, CoercedKeys])
      strict = StrictAtomKeys.new!(%{value: 1})
      assert {:ok, ^strict} = Catalog.validate(catalog, strict)

      assert_error(
        Catalog.decode(catalog, %{Signal.to_map(strict) | "data" => %{"value" => 1}}),
        :invalid_data
      )

      wire =
        Signal.new!(CoercedKeys.type(), %{"nested" => %{"value" => 1}}, source: "/wire")
        |> Signal.to_map()

      assert {:ok, decoded} = Catalog.decode(catalog, Jason.encode!(wire))
      assert decoded.data == %{"nested" => %{value: 1}}

      assert_error(
        Catalog.decode(catalog, put_in(wire, ["data", "nested", "value"], "1")),
        :invalid_data
      )
    end

    test "preserves bytes and explicit Base64 state" do
      catalog = Catalog.new!([BinaryData])

      for bytes <- [<<0, 255>>, "hello"] do
        wire = %{
          "specversion" => "1.0",
          "id" => "bytes",
          "source" => "/wire",
          "type" => BinaryData.type(),
          "data_base64" => Base.encode64(bytes)
        }

        assert {:ok, signal} = Catalog.decode(catalog, Jason.encode!(wire))
        assert signal.data == bytes
        assert signal.data_base64?
        assert Signal.to_map(signal) == wire
      end
    end

    test "rejects malformed envelopes and context without a fallback", %{catalog: catalog} do
      wire = Signal.to_map(message())

      for invalid <- [
            Map.delete(wire, "id"),
            Map.delete(wire, "specversion"),
            Map.put(wire, "badName", "x"),
            Map.put(wire, "extensions", %{}),
            Map.put(wire, "data_base64", "a"),
            %{1 => "invalid key"}
          ] do
        assert_error(Catalog.decode(catalog, invalid), :decode_failed)
        assert_error(Catalog.decode(catalog, Jason.encode!(invalid)), :decode_failed)
      end
    end

    test "rejects invalid shapes and JSON batches", %{catalog: catalog} do
      for input <- [nil, 1, [], message()] do
        assert_error(Catalog.decode(catalog, input), :invalid_input)
      end

      for json <- ["[", "null", "10", "[]", Jason.encode!([Signal.to_map(message())])] do
        assert_error(Catalog.decode(catalog, json), :decode_failed)
      end

      assert_error(Catalog.decode(nil, Signal.to_map(message())), :invalid_input)
    end

    test "forwards binary format and size options", %{catalog: catalog} do
      signal = message()
      json = Signal.serialize!(signal)
      assert {:ok, ^signal} = Catalog.decode(catalog, json, max_payload_bytes: byte_size(json))
      error = assert_error(Catalog.decode(catalog, json, max_payload_bytes: 1), :decode_failed)
      assert error.details.reason == {:payload_too_large, byte_size(json), 1}

      binary = Signal.serialize!(signal, format: :erlang_term)
      assert {:ok, ^signal} = Catalog.decode(catalog, binary, format: :erlang_term)
      assert_error(Catalog.decode(catalog, json, format: :unknown), :decode_failed)
      assert_error(Catalog.decode(catalog, json, [:invalid]), :decode_failed)
      assert_error(Catalog.decode(catalog, json, nil), :decode_failed)

      assert_error(
        Catalog.decode(catalog, Signal.to_map(signal), max_payload_bytes: 1),
        :invalid_options
      )
    end
  end

  def faulty_validator(:raise, _opts), do: raise(ArgumentError, "schema failed")
  def faulty_validator(:throw, _opts), do: throw(:schema_failed)
  def faulty_validator(:exit, _opts), do: exit(:schema_failed)

  defp message do
    MessageReceived.new!(%{"text" => "hello", "room" => "one"},
      id: "provider-fact-1",
      source: "/remote",
      subject: "room/one",
      time: "2026-10-12t12:03:04.123456z",
      datacontenttype: "application/json",
      extensions: %{
        "traceparent" => "00-12345678901234567890123456789012-1234567890123456-01",
        "attempt" => 1
      }
    )
  end

  defp assert_error(result, code) do
    assert {:error, %InvalidInputError{} = error} = result
    assert error.details.code == code
    error
  end
end
