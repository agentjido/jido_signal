# Jido Signal Usage Rules

## Intent
Model domain events as validated signals and route them predictably through dispatch and bus infrastructure.

## Core Contracts
- Use the five primary areas: Signal, Serialization, Router, Dispatch, and Bus.
- Prefer positional constructor: `Signal.new(type, data, attrs)`.
- Always supply `source`, unless a typed Signal defines `default_source`.
- Use dot-delimited event types (`user.created`, `order.shipped`).
- Use static Zoi schemas for typed Signal data. Use named MFA callbacks only.
- Use flat CloudEvents context attributes only for routing or processing metadata.
- Use JSON serialization by default. Use `format: :erlang_term` only between trusted Erlang systems.
- Use `Signal.to_map/1` and `Signal.from_map/1` as the only map conversion boundary.
- Carry W3C tracing with `Jido.Signal.Trace`; keep sampling and process context explicit.
- Publish as a list (`Bus.publish(bus, [signal])`) and keep routing explicit.
- Keep transport logic in dispatch adapters, not in signal payload modules.

## Library Author Patterns
- Define typed signal modules for important domain boundaries (billing, auth, workflow).
- Use router patterns intentionally: exact > `*` > `**`, with explicit priority when needed.
- For fanout workflows, route through `Jido.Signal.Bus`; for single targets, use direct dispatch.
- For durable consumers, select a durable Bus Store and use explicit acknowledgements.
- Acknowledge `RecordedSignal.id`, not the Signal envelope ID.
- Keep retry, concurrency, and rate-limit policy in the calling application.
- Keep domain fields in Signal `data`, not in context attributes.

## QA Patterns
- Test route precedence and wildcard matching (`exact`, `*`, `**`).
- Test subscriber lifecycle, continuous checkpoints, replay bounds, and DLQ redrive.

## Avoid
- Generic type names (`event`, `message`) that hide domain intent.
- Ad-hoc process messaging where signal routing/observability is required.
- Implicit persistence/replay assumptions.
- Journal, partition, and snapshot options removed in v3.
- Schema-backed Signal extension modules and Signal-owned dispatch metadata.
- General term serializers, dynamic type providers, and MessagePack.
- Process-dictionary trace state and Signal-owned sampling policy.

## References
- `README.md`
- `guides/v2-to-v3.md`
- `guides/`
- `AGENTS.md`
- https://hexdocs.pm/jido_signal
- https://hexdocs.pm/usage_rules/readme.html#usage-rules
