# Signal Model

Current-truth contract for constructing and validating Jido signal envelopes.

## Intent

Capture the behavior of the core `Jido.Signal` API and the `use Jido.Signal`
macro that typed signal modules rely on.

```spec-meta
id: jido_signal.signal_model
kind: module
status: active
summary: Signal constructors populate required CloudEvents-style fields, validate typed signal data, and preserve extension policy during construction and map conversion.
surface:
  - lib/jido_signal.ex
  - lib/jido_signal/using.ex
  - lib/jido_signal/ext.ex
  - lib/jido_signal/trace_context.ex
```

## Requirements

```spec-requirements
- id: jido_signal.signal_model.constructor_defaults
  statement: `Jido.Signal.new/1`, `new/3`, and `from_map/1` shall populate or validate the required envelope fields and reject malformed input.
  priority: must
  stability: stable

- id: jido_signal.signal_model.typed_schema_validation
  statement: Modules that `use Jido.Signal` shall validate data against the declared schema and apply configured default metadata during typed construction.
  priority: must
  stability: stable

- id: jido_signal.signal_model.extension_policy
  statement: Signal extensions shall be validated, stored, and reconstructed according to extension registry behavior and any typed-signal extension policy.
  priority: should
  stability: evolving
```

## Scenarios

```spec-scenarios
- id: jido_signal.signal_model.typed_construction_flow
  given:
    - a typed signal module declares a signal type, default metadata, and a validation schema
  when:
    - the caller constructs a signal with valid data and allowed attrs
  then:
    - the result is a signal envelope with validated payload data and required runtime metadata
  covers:
    - jido_signal.signal_model.constructor_defaults
    - jido_signal.signal_model.typed_schema_validation
```

## Verification

```spec-verification
- kind: command
  target: >-
    mix test test/jido_signal/signal/signal_test.exs
    test/jido_signal/signal_custom_test.exs
  execute: true
  covers:
    - jido_signal.signal_model.constructor_defaults
    - jido_signal.signal_model.typed_schema_validation
    - jido_signal.signal_model.typed_construction_flow

- kind: command
  target: >-
    mix test test/jido_signal/ext_test.exs test/jido_signal/ext
    test/jido_signal/trace_context_test.exs test/jido_signal/trace
  execute: true
  covers:
    - jido_signal.signal_model.extension_policy
```
