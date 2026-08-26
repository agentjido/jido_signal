# Serialization
<!-- covers: jido_signal.guides.serialization -->

Jido Signal serializes Signals, not general Elixir values. It supports JSON and
Erlang Term Format.

## Canonical Map

All formats use the same conversion path:

```text
Signal -> Jido.Signal.to_map/1 -> binary format
Signal <- Jido.Signal.from_map/1 <- binary format
```

The canonical map uses string keys and CloudEvents 1.0 field names. Extension
context attributes are flat top-level fields. New output does not include a
Jido schema version.

The reader accepts the v2 `jido_schema_version` values `1` and `2`. It also
normalizes the old `specversion` value `"1.0.2"` to `"1.0"`.

## JSON

JSON is the default format:

```elixir
signal =
  Jido.Signal.new!("user.created", %{"user_id" => "123"},
    source: "/accounts"
  )

{:ok, json} = Jido.Signal.serialize(signal)
{:ok, decoded} = Jido.Signal.deserialize(json)
```

Lists use the same API:

```elixir
{:ok, json} = Jido.Signal.serialize([first_signal, second_signal])
{:ok, signals} = Jido.Signal.deserialize(json)
```

## Erlang Term Format

Use Erlang Term Format only between trusted Erlang or Elixir systems:

```elixir
opts = [format: :erlang_term]

{:ok, binary} = Jido.Signal.serialize(signal, opts)
{:ok, decoded} = Jido.Signal.deserialize(binary, opts)
```

Jido writes the canonical map with `:erlang.term_to_binary/1`. It reads the map
with `:erlang.binary_to_term/2` and the `:safe` option.

## Signal Data

JSON-safe data stays in the CloudEvents `data` field. JSON-safe data includes:

- `nil`
- Booleans
- numbers
- valid UTF-8 strings
- proper lists of JSON-safe values
- maps with valid UTF-8 string keys and JSON-safe values

Binary data and other Erlang-only values use `data_base64`. Jido encodes these
values as follows:

```elixir
encoded = data |> :erlang.term_to_binary() |> Base.encode64()
```

The reader reverses these operations with the safe Erlang term option. The
`data` and `data_base64` fields are mutually exclusive.

This rule keeps atom keys, tuples, structs, and non-UTF-8 binaries intact. A
non-Jido consumer sees the decoded `data_base64` value as an Erlang external
term binary.

The `datacontenttype` field describes the data. It does not select a format and
does not transform the data.

## Typed Signals

Deserialization returns `%Jido.Signal{}`. It does not load an application module
from the Signal `type` value.

Use the known custom Signal module to validate data after routing:

```elixir
{:ok, signal} = Jido.Signal.deserialize(json)
{:ok, data} = MyApp.UserCreated.validate_data(signal.data)
```

This keeps module selection explicit. It also keeps Zoi as the only custom data
validation path.

## Payload Size

The default maximum encoded or decoded payload size is 10 MB. Set a limit for
one call:

```elixir
Jido.Signal.serialize(signal, max_payload_bytes: 1_000_000)
Jido.Signal.deserialize(binary, max_payload_bytes: 1_000_000)
```

Or configure the application limit:

```elixir
config :jido_signal, max_payload_bytes: 1_000_000
```

The limit applies after encoding and before decoding.

## Errors

Format errors use tagged tuples:

```elixir
{:error, {:json_decode_failed, message}}
{:error, {:erlang_term_decode_failed, message}}
{:error, {:payload_too_large, actual_size, maximum_size}}
{:error, {:unsupported_format, format}}
```

After format decoding, `Jido.Signal.from_map/1` validates the Signal envelope
and returns its validation error.

## Removed v2 Features

v3 does not include:

- MessagePack
- serializer behavior modules
- arbitrary struct serialization
- type providers
- the JSON decoder protocol
- runtime serializer mutation

Convert stored MessagePack values before the v3 upgrade.
