# Jido Signal Usage Rules

## Intent
Model domain events as validated signals and route them predictably through dispatch and bus infrastructure.

## Core Contracts
- Use the five primary areas: Signal, Serialization, Router, Dispatch, and Bus.
- Prefer positional constructor: `Signal.new(type, data, attrs)`.
- Always supply `source`, unless a typed Signal defines `default_source`.
- Use dot-delimited event types (`user.created`, `order.shipped`).
- Use static Zoi schemas for typed Signal data. Use named MFA callbacks only.
- Handle the Zoi errors returned by typed Signal validation without a package wrapper.
- Use flat CloudEvents context attributes only for routing or processing metadata.
- Use JSON serialization by default. Use `format: :erlang_term` only between trusted Erlang systems.
- Use `Signal.to_map/1` and `Signal.from_map/1` as the only map conversion boundary.
- Use only the small `Jido.Signal.ID` UUID7 API. Do not infer sequence order for IDs from the same millisecond.
- Carry W3C tracing with `Jido.Signal.Trace`; keep sampling and process context explicit.
- Publish as a list (`Bus.publish(bus, [signal])`) and keep routing explicit.
- Keep transport logic in dispatch adapters, not in signal payload modules.

## Library Author Patterns
- Define typed signal modules for important domain boundaries (billing, auth, workflow).
- Use router patterns intentionally: exact > `*` > `**`, with explicit priority when needed.
- Use Router management functions. Do not inspect Router implementation fields.
- For fanout workflows, route through `Jido.Signal.Bus`; for single targets, use direct dispatch.
- Use the HTTP adapter only for structured CloudEvents JSON `POST` delivery. Use a custom adapter for strict single-attempt delivery, request signing, or transport policy.
- Give each durable consumer a stable string ID and one active process.
- Acknowledge the delivered `RecordedSignal.cursor`, not either record ID.
- Expect at-least-once delivery and make durable handlers idempotent.
- Keep retry, concurrency, and rate-limit policy in the calling application.
- Keep domain fields in Signal `data`, not in context attributes.
- Use fixed application modules or atoms as `Jido.Signal.Instance` names. Never create them from runtime tenant data.

## QA Patterns
- Test route precedence and wildcard matching (`exact`, `*`, `**`).
- Test target exit, durable reattachment, ordered acknowledgement, and replay bounds.

## Avoid
- Generic type names (`event`, `message`) that hide domain intent.
- Ad-hoc process messaging where signal routing/observability is required.
- Implicit persistence/replay assumptions.
- Bus middleware, subscription dispatch targets, retry timers, and dead-letter policy.
- Journal, partition, and snapshot options removed in v3.
- Schema-backed Signal extension modules and Signal-owned dispatch metadata.
- General term serializers, dynamic type providers, and MessagePack.
- Process-dictionary trace state and Signal-owned sampling policy.
- HTTP method, retry, TLS, redirect, connection-pool, and Webhook policy in the built-in HTTP adapter.
- Direct use of package name-resolution and sanitization helpers. These helpers are internal.

## References
- `README.md`
- `guides/v2-to-v3.md`
- `guides/`
- `AGENTS.md`
- https://hexdocs.pm/jido_signal
- https://hexdocs.pm/usage_rules/readme.html#usage-rules
