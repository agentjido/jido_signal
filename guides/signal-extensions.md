# CloudEvents Context Attributes
<!-- covers: jido_signal.guides.signal_extensions -->

CloudEvents extension context attributes are optional transport metadata. A
Signal does not need an extension attribute to conform to CloudEvents 1.0.

Use a custom Signal module and a Zoi schema for domain data. Use context
attributes only when routing or processing infrastructure needs small metadata
that is not part of the event data.

## Use a Custom Signal for Domain Data

```elixir
defmodule MyApp.UserCreated do
  use Jido.Signal,
    type: "user.created",
    default_source: "/accounts",
    schema:
      Zoi.object(%{
        user_id: Zoi.string(),
        email: Zoi.string()
      })
end

{:ok, signal} =
  MyApp.UserCreated.new(%{
    user_id: "user-123",
    email: "user@example.com"
  })
```

This schema validates the `data` field. It gives the domain event a stable
contract. Schema callbacks must use named MFA values so the compiler can store
and check the schema.

## Add Small Context Values

```elixir
{:ok, signal} = Jido.Signal.put_context(signal, "tenantid", "tenant-123")
{:ok, signal} = Jido.Signal.put_context(signal, "attempt", 2)
{:ok, signal} = Jido.Signal.put_context(signal, "sampled", true)

"tenant-123" = Jido.Signal.get_context(signal, "tenantid")
["attempt", "sampled", "tenantid"] =
  signal |> Jido.Signal.list_context() |> Enum.sort()

signal = Jido.Signal.delete_context(signal, "attempt")
```

The internal `extensions` field is a map. The canonical wire map moves each
entry to the top level:

```elixir
wire = Jido.Signal.to_map(signal)
wire["tenantid"]
#=> "tenant-123"

Map.has_key?(wire, "extensions")
#=> false
```

`Jido.Signal.from_map/1` moves unknown valid top-level context attributes back
to `signal.extensions`.

## Name and Value Rules

Jido enforces these extension name rules:

- Start with a lower-case letter.
- Use lower-case letters and digits only.
- Use no more than 20 characters.
- Do not use a core CloudEvents attribute name such as `data` or `type`.

Values must be a CloudEvents context value. In Elixir, use a Boolean, signed
32-bit Integer, or binary. URI, URI-reference, Timestamp, and String values use
binaries.

Do not put maps, lists, tuples, PIDs, or dispatch configurations in context
attributes.

## Trace Context

`Jido.Signal.Trace` stores W3C trace data in flat attributes. It uses
`traceparent`, optional `tracestate`, and small Jido correlation attributes.

```elixir
context = Jido.Signal.Trace.new_root()
{:ok, traced_signal} = Jido.Signal.Trace.put(signal, context)

Jido.Signal.to_map(traced_signal)["traceparent"]
#=> "00-...-...-01"
```

## Dispatch Is Not Signal Metadata

Select a dispatch target at the delivery boundary:

```elixir
:ok = Jido.Signal.Dispatch.dispatch(signal, {:logger, level: :info})

{:ok, subscription_id} =
  Jido.Signal.Bus.subscribe(:events, "user.*",
    dispatch: {:pid, target: handler_pid}
  )
```

This keeps transport state out of the core event data structure.
