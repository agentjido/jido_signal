# Jido Signal Usage Rules

## Intent
Model domain events as validated signals and route them predictably through dispatch and bus infrastructure.

## Core Contracts
- Prefer positional constructor: `Signal.new(type, data, attrs)`.
- Use dot-delimited event types (`user.created`, `order.shipped`).
- Use Zoi schemas for typed signal modules and extensions.
- Publish as a list (`Bus.publish(bus, [signal])`) and keep routing explicit.
- Keep transport logic in dispatch adapters, not in signal payload modules.

## Library Author Patterns
- Define typed signal modules for important domain boundaries (billing, auth, workflow).
- Use router patterns intentionally: exact > `*` > `**`, with explicit priority when needed.
- For fanout workflows, route through `Jido.Signal.Bus`; for single targets, use direct dispatch.
- For durable consumers, select a durable Bus Store and use explicit acknowledgements.
- Acknowledge `RecordedSignal.id`, not the Signal envelope ID.
- Keep retry, concurrency, and rate-limit policy in the calling application.

## QA Patterns
- Test route precedence and wildcard matching (`exact`, `*`, `**`).
- Test subscriber lifecycle, continuous checkpoints, replay bounds, and DLQ redrive.

## Avoid
- Generic type names (`event`, `message`) that hide domain intent.
- Ad-hoc process messaging where signal routing/observability is required.
- Implicit persistence/replay assumptions.
- Journal, partition, and snapshot options removed in v3.

## References
- `README.md`
- `guides/`
- `AGENTS.md`
- https://hexdocs.pm/jido_signal
- https://hexdocs.pm/usage_rules/readme.html#usage-rules
