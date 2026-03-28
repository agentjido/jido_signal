# Extensions And Tracing

Current-truth contract for extension registration, safe extension handling, and
trace context propagation.

## Intent

Describe the extension system and tracing helpers that enrich signals without
changing the core envelope model.

```spec-meta
id: jido_signal.extensions_trace
kind: subsystem
status: active
summary: Extensions register by namespace, validate and serialize safely, and tracing utilities propagate W3C-style context through signals and process-local state.
surface:
  - lib/jido_signal/ext.ex
  - lib/jido_signal/ext/registry.ex
  - lib/jido_signal/ext/trace.ex
  - lib/jido_signal/ext/dispatch.ex
  - lib/jido_signal/trace.ex
  - lib/jido_signal/trace_context.ex
  - lib/jido_signal/trace/context.ex
```

## Requirements

```spec-requirements
- id: jido_signal.extensions_trace.extension_registration
  statement: Extensions shall declare a valid namespace, auto-register in the extension registry, and expose the callbacks required by the extension behaviour.
  priority: must
  stability: stable

- id: jido_signal.extensions_trace.safe_extension_handling
  statement: Extension data shall validate against declared schemas, serialize and deserialize through extension callbacks, and safely ignore or report unsupported extension inputs.
  priority: must
  stability: stable

- id: jido_signal.extensions_trace.trace_propagation
  statement: Trace helpers shall create and validate trace context, translate to and from W3C traceparent values, and propagate child context through signals or process-local trace state.
  priority: must
  stability: evolving
```

## Scenarios

```spec-scenarios
- id: jido_signal.extensions_trace.child_span_propagation
  given:
    - a signal is processed with an existing trace or traceparent context
  when:
    - downstream work creates a child signal or child span
  then:
    - the child trace inherits the parent trace id and links causation through the parent span
  covers:
    - jido_signal.extensions_trace.trace_propagation
```

## Verification

```spec-verification
- kind: command
  target: >-
    mix test test/jido_signal/ext_test.exs test/jido_signal/ext
    test/jido_signal/trace_test.exs test/jido_signal/trace_context_test.exs
    test/jido_signal/trace
  execute: true
  covers:
    - jido_signal.extensions_trace.extension_registration
    - jido_signal.extensions_trace.safe_extension_handling
    - jido_signal.extensions_trace.trace_propagation
    - jido_signal.extensions_trace.child_span_propagation
```
