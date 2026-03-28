# Serialization

Current-truth contract for encoding, decoding, and configuring signal
serialization behavior.

## Intent

Describe the supported serializer formats, default configuration, and
defensive decoding rules for signal and struct round trips.

```spec-meta
id: jido_signal.serialization
kind: subsystem
status: active
summary: Serialization supports configurable defaults, multiple formats, type-aware decoding, and bounded/safe deserialization.
surface:
  - lib/jido_signal/serialization/config.ex
  - lib/jido_signal/serialization/serializer.ex
  - lib/jido_signal/serialization/json_serializer.ex
  - lib/jido_signal/serialization/json_decoder.ex
  - lib/jido_signal/serialization/msgpack_serializer.ex
  - lib/jido_signal/serialization/erlang_term_serializer.ex
  - lib/jido_signal/serialization/schema.ex
  - lib/jido_signal/serialization/type_provider.ex
  - lib/jido_signal/serialization/module_name_type_provider.ex
  - lib/jido_signal/serialization/cloud_events_transform.ex
  - test/jido_signal/serialization_test.exs
  - test/jido_signal/serialization
  - test/jido_signal/signal/serialization
  - test/jido_signal/signal/*serialization*.exs
```

## Requirements

```spec-requirements
- id: jido_signal.serialization.default_configuration
  statement: Serialization configuration shall expose runtime defaults for serializer, type provider, and payload limits and validate that configured modules implement the expected behaviours.
  priority: must
  stability: stable

- id: jido_signal.serialization.round_trip_formats
  statement: Signal and struct serialization shall round-trip through the supported JSON, MessagePack, and Erlang term serializers with type-provider-aware decoding where applicable.
  priority: must
  stability: stable

- id: jido_signal.serialization.defensive_decoding
  statement: Deserialization shall reject invalid payloads, enforce schema and payload safety checks, and avoid unsafe type reconstruction.
  priority: must
  stability: stable
```

## Scenarios

```spec-scenarios
- id: jido_signal.serialization.typed_round_trip
  given:
    - a signal or struct is serialized with type information and one of the built-in serializers
  when:
    - the payload is deserialized with the matching configuration
  then:
    - the result preserves the intended data shape or returns a structured error when the payload is invalid
  covers:
    - jido_signal.serialization.round_trip_formats
    - jido_signal.serialization.defensive_decoding
```

## Verification

```spec-verification
- kind: command
  target: >-
    mix test test/jido_signal/serialization_test.exs test/jido_signal/serialization
    test/jido_signal/signal/serialization test/jido_signal/signal/signal_serialization_test.exs
    test/jido_signal/signal/serialization_strategies_test.exs
    test/jido_signal/signal/recorded_signal_serialization_test.exs
  execute: true
  covers:
    - jido_signal.serialization.default_configuration
    - jido_signal.serialization.round_trip_formats
    - jido_signal.serialization.defensive_decoding
    - jido_signal.serialization.typed_round_trip
```
