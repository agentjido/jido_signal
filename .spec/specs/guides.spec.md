# Guides

Current-truth contract for the maintained guide set.

## Intent

Describe the user-facing guide surfaces that explain the package's primary
workflows and advanced usage patterns.

```spec-meta
id: jido_signal.guides
kind: doc
status: active
summary: The repository keeps guide coverage for getting started, signal construction and dispatch, routing, event bus usage, serialization, extensions, journal usage, and advanced operational patterns.
surface:
  - guides/getting-started.md
  - guides/signals-and-dispatch.md
  - guides/signal-router.md
  - guides/event-bus.md
  - guides/serialization.md
  - guides/signal-extensions.md
  - guides/signal-journal.md
  - guides/advanced.md
decisions:
  - jido_signal.decision.spec_led_repo_workflow
```

## Requirements

```spec-requirements
- id: jido_signal.guides.getting_started
  statement: The getting started guide shall show installation, bus setup, basic signal creation, dispatch, and instance isolation entry points.
  priority: should
  stability: evolving

- id: jido_signal.guides.signals_and_dispatch
  statement: The signals and dispatch guide shall explain signal structure, IDs, dispatch modes, and custom typed signal construction.
  priority: should
  stability: evolving

- id: jido_signal.guides.signal_router
  statement: The signal router guide shall document route patterns, wildcard matching, priority behavior, and dynamic route management.
  priority: should
  stability: evolving

- id: jido_signal.guides.event_bus
  statement: The event bus guide shall cover publish/subscribe usage, middleware, persistent subscriptions, replay or snapshots, and instance isolation.
  priority: should
  stability: evolving

- id: jido_signal.guides.serialization
  statement: The serialization guide shall describe built-in serializers, runtime configuration, type providers, and custom serializer extension points.
  priority: should
  stability: evolving

- id: jido_signal.guides.signal_extensions
  statement: The signal extensions guide shall explain extension definition, namespace usage, serialization behavior, and multi-extension composition.
  priority: should
  stability: evolving

- id: jido_signal.guides.signal_journal
  statement: The signal journal guide shall explain journal purpose, adapters, causality tracking, checkpoints, and dead-letter usage.
  priority: should
  stability: evolving

- id: jido_signal.guides.advanced_usage
  statement: The advanced usage guide shall document custom adapters, operational error handling patterns, reliable delivery strategies, and testing techniques.
  priority: should
  stability: evolving
```

## Verification

```spec-verification
- kind: guide_file
  target: guides/getting-started.md
  covers:
    - jido_signal.guides.getting_started

- kind: guide_file
  target: guides/signals-and-dispatch.md
  covers:
    - jido_signal.guides.signals_and_dispatch

- kind: guide_file
  target: guides/signal-router.md
  covers:
    - jido_signal.guides.signal_router

- kind: guide_file
  target: guides/event-bus.md
  covers:
    - jido_signal.guides.event_bus

- kind: guide_file
  target: guides/serialization.md
  covers:
    - jido_signal.guides.serialization

- kind: guide_file
  target: guides/signal-extensions.md
  covers:
    - jido_signal.guides.signal_extensions

- kind: guide_file
  target: guides/signal-journal.md
  covers:
    - jido_signal.guides.signal_journal

- kind: guide_file
  target: guides/advanced.md
  covers:
    - jido_signal.guides.advanced_usage
```
