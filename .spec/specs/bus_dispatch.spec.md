# Bus And Dispatch

Current-truth contract for publishing signals and delivering them to subscribers.

## Intent

Describe the bus, replay, persistence, and adapter-based delivery behavior that
turns signal envelopes into observable system effects.

```spec-meta
id: jido_signal.bus_dispatch
kind: subsystem
status: active
summary: The bus manages subscriptions, ordered publish/replay, adapter-based delivery, and the runtime registry, telemetry, and instance-aware helpers those flows depend on.
surface:
  - lib/jido_signal/application.ex
  - lib/jido_signal/bus.ex
  - lib/jido_signal/bus
  - lib/jido_signal/bus_spy.ex
  - lib/jido_signal/dispatch.ex
  - lib/jido_signal/dispatch
  - lib/jido_signal/instance.ex
  - lib/jido_signal/names.ex
  - lib/jido_signal/registry.ex
  - lib/jido_signal/telemetry.ex
  - lib/jido_signal/util.ex
  - test/jido_signal/bus/bus_supervision_test.exs
  - test/jido_signal/bus/partition_test.exs
  - test/jido_signal/bus_instance_isolation_test.exs
  - test/jido_signal/signal/bus*.exs
  - test/jido_signal/signal/registry_test.exs
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

- id: jido_signal.bus_dispatch.runtime_support
  statement: The bus runtime shall start shared registry or task infrastructure, resolve instance-scoped names, and emit telemetry hooks that support observability and bus spy capture.
  priority: should
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
    - jido_signal.bus_dispatch.runtime_support
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
    - jido_signal.bus_dispatch.runtime_support
    - jido_signal.bus_dispatch.matching_subscriber_delivery
```
