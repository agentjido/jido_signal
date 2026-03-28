# Dispatch Adapters

Current-truth contract for validating dispatch configs and delivering signals
through built-in adapters.

## Intent

Describe the dispatch layer behavior that normalizes configuration, fans out to
multiple destinations, and surfaces adapter-specific failures.

```spec-meta
id: jido_signal.dispatch_adapters
kind: subsystem
status: active
summary: Dispatch validates configs, supports the built-in adapters, and handles single, async, and parallel multi-target delivery paths.
surface:
  - lib/jido_signal/dispatch.ex
  - lib/jido_signal/dispatch/adapter.ex
  - lib/jido_signal/dispatch/pid.ex
  - lib/jido_signal/dispatch/bus.ex
  - lib/jido_signal/dispatch/named.ex
  - lib/jido_signal/dispatch/pubsub.ex
  - lib/jido_signal/dispatch/logger.ex
  - lib/jido_signal/dispatch/console.ex
  - lib/jido_signal/dispatch/noop.ex
  - lib/jido_signal/dispatch/http.ex
  - lib/jido_signal/dispatch/webhook.ex
  - lib/jido_signal/dispatch/circuit_breaker.ex
```

## Requirements

```spec-requirements
- id: jido_signal.dispatch_adapters.config_validation
  statement: Dispatch shall validate single or multiple adapter configs and reject malformed or unsupported dispatch options before delivery.
  priority: must
  stability: stable

- id: jido_signal.dispatch_adapters.builtin_delivery
  statement: Dispatch shall route signals through the supported built-in adapters and custom adapter modules that implement the adapter behaviour.
  priority: must
  stability: stable

- id: jido_signal.dispatch_adapters.parallel_and_batch
  statement: Dispatch shall support async, parallel multi-target, and batched delivery while preserving aggregate error reporting semantics.
  priority: should
  stability: evolving
```

## Scenarios

```spec-scenarios
- id: jido_signal.dispatch_adapters.multi_target_delivery
  given:
    - a signal is dispatched to multiple built-in adapters at once
  when:
    - one or more destinations fail
  then:
    - the dispatch result reflects the aggregate outcome instead of silently dropping adapter failures
  covers:
    - jido_signal.dispatch_adapters.builtin_delivery
    - jido_signal.dispatch_adapters.parallel_and_batch
```

## Verification

```spec-verification
- kind: command
  target: >-
    mix test test/jido_signal/dispatch test/jido_signal/dispatch/adapters
  execute: true
  covers:
    - jido_signal.dispatch_adapters.config_validation
    - jido_signal.dispatch_adapters.builtin_delivery
    - jido_signal.dispatch_adapters.parallel_and_batch
    - jido_signal.dispatch_adapters.multi_target_delivery
```
