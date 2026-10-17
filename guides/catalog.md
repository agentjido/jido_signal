# Typed Signal Catalog
<!-- covers: jido_signal.guides.catalog -->

Use `Jido.Signal.Catalog` to decode a Signal and validate its domain data in
one call. Supply the definition modules explicitly. A catalog is an immutable
value. It needs no process or global registration.

## When To Use A Catalog

Use a Catalog at an input boundary when an incoming event must match one of
your known domain definitions. Ordinary deserialization validates the envelope;
a Catalog also selects a definition and validates its data schema. It does not
route or deliver the result.

## Define and Register Signals

Each domain owns its definitions. These message and sensor examples use the
same catalog API. They require no domain package dependency.

```elixir
defmodule MyApp.MessageReceived do
  use Jido.Signal,
    type: "example.message.received",
    default_source: "/messages",
    dataschema: "https://example.com/schemas/message/v1",
    schema:
      Zoi.object(
        %{"text" => Zoi.string(), "room" => Zoi.string()},
        unrecognized_keys: :error
      )
end

defmodule MyApp.TemperatureMeasured do
  use Jido.Signal,
    type: "example.sensor.temperature",
    default_source: "/sensors",
    schema: Zoi.object(%{"celsius" => Zoi.number()})
end

alias Jido.Signal
alias Jido.Signal.Catalog

{:ok, catalog} = Catalog.new([MyApp.MessageReceived, MyApp.TemperatureMeasured])
# Or: catalog = Catalog.new!([MyApp.MessageReceived, MyApp.TemperatureMeasured])

{:ok, signal} = MyApp.MessageReceived.new(%{"text" => "hello", "room" => "one"})
{:ok, json} = Signal.serialize(signal)
{:ok, decoded} = Catalog.decode(catalog, json)
true = decoded.id == signal.id
{:ok, decoded} = Catalog.validate(catalog, decoded)
```

The catalog validates and captures one snapshot of each definition's existing
metadata. It uses the Signal envelope's type and schema URI validation rules.
Use `new/1` or `new!/1` to create a catalog. Its internal representation is
opaque. Replacing a definition module does not change an existing catalog's
captured metadata. Build a new catalog to use the replacement definition.

## Exact Schema Identity

`dataschema` is the optional schema URI attribute from the
[CloudEvents 1.0 specification](https://github.com/cloudevents/spec/blob/v1.0.2/cloudevents/spec.md#dataschema).
It can be an HTTP URI or a URN. Use a different URI for an incompatible data
schema. The exact pair lookup below is the catalog's local selection rule.

The lookup key is the exact `{type, dataschema}` pair. There is no wildcard
matching, URI normalization, remote schema fetch, or version fallback.

A definition without `dataschema` matches only an absent or null wire
`dataschema`, which the codec reads as `nil`. An explicit schema URI does not
match that definition. Multiple definitions can share a type if their schema
identities differ. Duplicate pairs are rejected, including repeated modules.
To combine definition families, pass their combined module list to `new/1`.

Use a separate definition for each data version. The domain owner must choose
any data migration. A catalog does not migrate an old schema to a new one.

Custom constructors keep their definition's `type`, `dataschema`, and validated
`data`. This includes `nil` when the definition has no `dataschema`. Options
cannot change those values. Source, ID, time, subject, content type, and context
can still be supplied under their existing envelope rules.

This `dataschema` rule changes the earlier v3 beta behavior, which allowed
custom constructor options to override it. Replace that override with a
separate definition for the required schema identity. Generic `Signal.new/1`
and `Signal.new/3` retain their existing `dataschema` behavior.

## Wire and Data Keys

`decode/2` accepts one complete canonical wire map or JSON binary. It uses
`Signal.from_map/1` or `Signal.Serialization.deserialize/2`. The codec accepts
atom or string envelope keys and rejects duplicate normalized attributes.
Wire maps require `specversion`, ID, source, and type. Definition defaults do
not fill missing wire attributes. Flat extensions use the existing context
validation. Invalid input returns an error without a raw-map fallback.

Domain data uses the selected Zoi schema exactly as typed construction does.
The catalog does not enable extra coercion. A strict atom-key object does not
accept string keys from JSON. A definition can set `coerce: true` on selected
Zoi objects to accept both key forms. Zoi returns the keys declared in that
schema and does not create atoms from unknown input keys. Value coercion must
also be declared by the schema.

Use string-key objects for portable JSON data, as in the examples above.
Generic JSON serialization still rejects atom-key data. If a schema produces
atom keys, use trusted Erlang Term Format or convert data through a separate
domain contract before JSON serialization. The catalog does not rewrite the
generic serializer's data rules.

## Identity and Options

`validate/2` accepts an existing `%Jido.Signal{}`. It validates the envelope,
flat context, exact definition identity, and domain data. It does not call a
constructor or generate an ID. ID, time spelling and precision, source,
subject, content type, and valid context values remain intact. Context names
are normalized to strings. Definition data defaults and transforms can change
the data value. Schema callbacks must be suitable for repeated validation.
When data changes, the codec normalizes its presence and Base64 flags. Absent
data and explicit null data keep their separate meanings when validation
leaves the data unchanged. Invalid context on an existing Signal returns an
error before envelope defaults can replace it.

Binary decode options go to the existing serializer:

```elixir
Catalog.decode(catalog, json, max_payload_bytes: 1_000_000)
Catalog.decode(catalog, trusted_binary, format: :erlang_term)
```

The normal 10 MB application limit applies to binary input. Wire maps accept
no options and have no encoded-byte size limit. The API accepts one Signal.
It rejects lists and JSON batches. Validate multiple Signals explicitly when
the application owns a batch contract.

## Structured Errors

All catalog errors use `{:error, %Jido.Signal.Error.InvalidInputError{}}`.
Use `error.details.code` for classification:

| Code | Meaning | Further details |
| --- | --- | --- |
| `:invalid_definitions` | Registration input or metadata is invalid, or a metadata callback failed. | `reason`: Zoi errors or `{kind, value}`; metadata errors also include `definition` |
| `:duplicate_definition` | An exact pair was registered twice. | `type`, `dataschema`, `definitions` in registration order |
| `:invalid_input` | The catalog or input shape is invalid. | `field` |
| `:invalid_options` | Options were supplied for a map. | `field: :options` |
| `:decode_failed` | Wire format/envelope is invalid, input is a batch, or the codec failed. | `reason`: original codec/serialization error, batch error, or `{kind, value}` |
| `:invalid_envelope` | Existing Signal or context is invalid. | `reason`: Zoi errors or context error |
| `:unknown_type` | No definition has this type. | `type`, `dataschema` |
| `:unknown_dataschema` | The type is known but the schema identity is not. | `type`, `dataschema` |
| `:invalid_data` | The selected schema rejected data. | `type`, `dataschema`, `definition`, `reason`: Zoi errors |
| `:validation_failed` | A trusted schema callback raised, threw, or exited. | `type`, `dataschema`, `definition`, `reason`: `{kind, value}` |

`Catalog.new!/1` raises the same error for invalid registration. Use
`Jido.Signal.Error.to_map/1` when you need a sanitized public error map:

```elixir
{:error, error} = Catalog.validate(catalog, invalid_signal)
public_error = Jido.Signal.Error.to_map(error)
```

Registration and schema callbacks are trusted application code. The catalog
does not authorize operations, execute commands, or define domain delivery
policy. Type and schema values in input select only the supplied definitions.
