# Journal And Persistence

Current-truth contract for durable signal history, causality tracking, and
reliable subscription state.

## Intent

Describe the journal adapters and persistent subscription behavior that preserve
signal history, checkpoints, and dead-letter handling.

```spec-meta
id: jido_signal.journal_persistence
kind: subsystem
status: active
summary: The journal records signals plus causal relationships, and persistence adapters back checkpoints and DLQ behavior used by reliable subscriptions.
surface:
  - lib/jido_signal/journal.ex
  - lib/jido_signal/journal/persistence.ex
  - lib/jido_signal/journal/adapters/in_memory.ex
  - lib/jido_signal/journal/adapters/ets.ex
  - lib/jido_signal/journal/adapters/mnesia.ex
  - lib/jido_signal/journal/adapters/mnesia/tables.ex
  - lib/jido_signal/bus/persistent_subscription.ex
  - test/jido_signal/journal
  - test/jido_signal/signal/journal
  - test/jido_signal/signal/journal_test.exs
  - test/jido_signal/signal/bus_persistence_test.exs
  - test/jido_signal/bus/bus_journal_test.exs
  - test/jido_signal/bus/dlq_test.exs
  - test/jido_signal/bus/persistent_subscription_test.exs
```

## Requirements

```spec-requirements
- id: jido_signal.journal_persistence.causality_and_query
  statement: The journal shall record signals, maintain conversation and cause/effect relationships, and query or trace stored signals in chronological order.
  priority: must
  stability: stable

- id: jido_signal.journal_persistence.adapter_callbacks
  statement: Persistence adapters shall implement checkpoint and dead-letter operations for subscriptions in addition to core signal storage callbacks.
  priority: must
  stability: stable

- id: jido_signal.journal_persistence.reliable_subscription_recovery
  statement: Persistent subscriptions shall bound in-flight and pending queues, persist checkpoints, retry failed deliveries, and move exhausted deliveries to the DLQ.
  priority: must
  stability: evolving
```

## Scenarios

```spec-scenarios
- id: jido_signal.journal_persistence.retry_then_dlq
  given:
    - a persistent subscription uses a journal-backed adapter and delivery continues to fail
  when:
    - the subscription exhausts its allowed retry attempts
  then:
    - the failed delivery is preserved in the dead-letter queue and successful acknowledgements still advance checkpoints
  covers:
    - jido_signal.journal_persistence.adapter_callbacks
    - jido_signal.journal_persistence.reliable_subscription_recovery
```

## Verification

```spec-verification
- kind: command
  target: >-
    mix test test/jido_signal/signal/journal_test.exs test/jido_signal/journal
    test/jido_signal/signal/journal/adapters/ets_test.exs
    test/jido_signal/signal/journal/adapters/mnesia_test.exs
    test/jido_signal/signal/bus_persistence_test.exs test/jido_signal/bus/persistent_subscription_test.exs
    test/jido_signal/bus/bus_journal_test.exs test/jido_signal/bus/dlq_test.exs
  execute: true
  covers:
    - jido_signal.journal_persistence.causality_and_query
    - jido_signal.journal_persistence.adapter_callbacks
    - jido_signal.journal_persistence.reliable_subscription_recovery
    - jido_signal.journal_persistence.retry_then_dlq
```
