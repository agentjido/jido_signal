# Bus And Dispatch

Current-truth contract for publishing signals and delivering them to subscribers.

## Intent

Describe the bus, replay, persistence, and adapter-based delivery behavior that
turns signal envelopes into observable system effects.

```spec-meta
id: jido_signal.bus_dispatch
kind: subsystem
status: active
summary: The bus manages subscriptions, ordered publish/replay, and adapter-based delivery with persistence and instance-aware infrastructure hooks.
surface:
  - lib/jido_signal/bus.ex
  - lib/jido_signal/bus
  - lib/jido_signal/dispatch.ex
  - lib/jido_signal/dispatch
  - lib/jido_signal/instance.ex
```

## Requirements

```spec-requirements
- id: jido_signal.bus_dispatch.subscription_lifecycle
  statement: The bus shall let callers subscribe and unsubscribe by path, including optional persistent subscription behavior and dispatch configuration.
  priority: must
  stability: stable

- id: jido_signal.bus_dispatch.publish_and_replay
  statement: The bus shall publish matching signals in recorded order, retain them in a replayable log, and surface invalid publish input as errors.
  priority: must
  stability: stable

- id: jido_signal.bus_dispatch.adapter_delivery
  statement: The dispatch layer shall normalize adapter options and deliver signals through supported adapters and bus-backed subscribers.
  priority: must
  stability: evolving
```

## Scenarios

```spec-scenarios
- id: jido_signal.bus_dispatch.matching_subscriber_delivery
  given:
    - a bus has a subscriber whose path matches a signal type
  when:
    - the signal is published
  then:
    - the subscriber or configured adapter receives the recorded signal delivery
  covers:
    - jido_signal.bus_dispatch.subscription_lifecycle
    - jido_signal.bus_dispatch.publish_and_replay
    - jido_signal.bus_dispatch.adapter_delivery
```

## Verification

```spec-verification
- kind: command
  target: >-
    mix test test/jido_signal/bus test/jido_signal/dispatch
    test/jido_signal/signal/bus_test.exs test/jido_signal/signal/bus_e2e_test.exs
    test/jido_signal/signal/bus_persistence_test.exs test/jido_signal/signal/journal_test.exs
    test/jido_signal/bus_instance_isolation_test.exs
  execute: true
  covers:
    - jido_signal.bus_dispatch.subscription_lifecycle
    - jido_signal.bus_dispatch.publish_and_replay
    - jido_signal.bus_dispatch.adapter_delivery
    - jido_signal.bus_dispatch.matching_subscriber_delivery
```
