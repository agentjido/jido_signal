# Jido.Signal Package

High-level contract for the Jido.Signal package.

## Intent

Describe the package-level behavior and entrypoint metadata that callers rely
on before they drop into individual subjects such as signal construction,
routing, or bus operations.

```spec-meta
id: jido_signal.package
kind: package
status: active
summary: Jido.Signal provides validated signal envelopes plus routing, delivery, serialization, instance-scoped infrastructure, and package metadata that points users to canonical docs and the default Jido website.
surface:
  - README.md
  - mix.exs
  - lib/jido_signal.ex
  - lib/jido_signal/router.ex
  - lib/jido_signal/bus.ex
  - lib/jido_signal/dispatch.ex
  - lib/jido_signal/instance.ex
  - lib/mix/tasks/jido_signal.install.ex
  - test/jido_signal_test.exs
  - test/jido_signal/docs_examples_test.exs
  - test/mix/tasks/jido_signal.install_test.exs
  - test/support
  - test/test_helper.exs
decisions:
  - jido_signal.decision.spec_led_repo_workflow
```

## Requirements

```spec-requirements
- id: jido_signal.package.signal_model
  statement: The package shall let callers construct CloudEvents-style signals directly or via typed signal modules with validation and extensions.
  priority: must
  stability: stable

- id: jido_signal.package.routing_and_delivery
  statement: The package shall let callers route signals by exact and wildcard paths and deliver them through bus subscriptions or direct dispatch adapters.
  priority: must
  stability: stable

- id: jido_signal.package.serialization_and_isolation
  statement: The package shall let callers serialize signals and run signal infrastructure per named instance when isolation is required.
  priority: should
  stability: evolving

- id: jido_signal.package.installation_entrypoint
  statement: The package shall expose a `mix jido_signal.install` task that guides adopters to the getting-started flow and fails clearly when Igniter support is unavailable.
  priority: should
  stability: stable
```

## Verification

```spec-verification
- kind: command
  target: >-
    mix test test/jido_signal/signal/signal_test.exs test/jido_signal/signal_custom_test.exs
    test/jido_signal/ext_test.exs test/jido_signal/ext test/jido_signal/trace_context_test.exs
    test/jido_signal/trace
  execute: true
  covers:
    - jido_signal.package.signal_model

- kind: command
  target: >-
    mix test test/jido_signal/router test/jido_signal/dispatch
    test/jido_signal/signal/bus_test.exs test/jido_signal/signal/bus_e2e_test.exs
  execute: true
  covers:
    - jido_signal.package.routing_and_delivery

- kind: command
  target: >-
    mix test test/jido_signal/serialization_test.exs test/jido_signal/signal/serialization
    test/jido_signal/instance_test.exs test/jido_signal/bus_instance_isolation_test.exs
  execute: true
  covers:
    - jido_signal.package.serialization_and_isolation

- kind: command
  target: mix test test/mix/tasks/jido_signal.install_test.exs
  execute: true
  covers:
    - jido_signal.package.installation_entrypoint
```
