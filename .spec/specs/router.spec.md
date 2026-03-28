# Router

Current-truth contract for trie-based signal routing.

## Intent

Describe the route normalization and match-order behavior that subscribers and
bus internals depend on when resolving signal types to handlers.

```spec-meta
id: jido_signal.router
kind: module
status: active
summary: The router normalizes route specs, rejects invalid patterns, and resolves handlers by specificity, wildcard behavior, and priority.
surface:
  - lib/jido_signal/router.ex
  - lib/jido_signal/router/engine.ex
  - lib/jido_signal/router/validator.ex
  - lib/jido_signal/router/cache.ex
```

## Requirements

```spec-requirements
- id: jido_signal.router.route_validation
  statement: `Jido.Signal.Router` shall reject invalid path patterns, malformed match functions, and out-of-range priorities when routes are built or normalized.
  priority: must
  stability: stable

- id: jido_signal.router.match_resolution
  statement: The router shall match exact paths, single wildcards, multi-level wildcards, and predicate routes against signal types.
  priority: must
  stability: stable

- id: jido_signal.router.precedence_order
  statement: When multiple routes match, the router shall return handlers in deterministic precedence order based on specificity, priority, and registration order.
  priority: must
  stability: stable
```

## Scenarios

```spec-scenarios
- id: jido_signal.router.specific_before_wildcard
  given:
    - the router contains both specific and wildcard routes that match a signal type
  when:
    - the signal is routed
  then:
    - the returned handler list preserves the router's specificity and priority ordering
  covers:
    - jido_signal.router.match_resolution
    - jido_signal.router.precedence_order
```

## Verification

```spec-verification
- kind: command
  target: mix test test/jido_signal/router
  execute: true
  covers:
    - jido_signal.router.route_validation
    - jido_signal.router.match_resolution
    - jido_signal.router.precedence_order
    - jido_signal.router.specific_before_wildcard
```
