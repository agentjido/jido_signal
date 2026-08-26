# CloudEvents Context Attributes
<!-- covers: jido_signal.guides.signal_extensions -->

CloudEvents extension context attributes are optional transport metadata. A
Signal does not need an extension attribute to conform to CloudEvents 1.0.

Version 3 uses the context API only. Replace `put_extension/3`,
`get_extension/2`, `delete_extension/2`, and `list_extensions/1` with
`put_context/3`, `get_context/2`, `delete_context/2`, and `list_context/1`.

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

`Jido.Signal.Trace` stores W3C trace data in the flat `traceparent` and optional
`tracestate` attributes.

```elixir
trace = Jido.Signal.Trace.new(trace_flags: "01")
{:ok, traced_signal} = Jido.Signal.Trace.put(signal, trace)

Jido.Signal.to_map(traced_signal)["traceparent"]
#=> "00-...-...-01"
```

Create a child value when an outgoing Signal must continue the same trace:

```elixir
child = Jido.Signal.Trace.child(trace)
{:ok, outgoing_signal} = Jido.Signal.Trace.put(outgoing_signal, child)
```

Jido Signal does not keep trace context in the process dictionary. The caller
or tracing system owns span lifetime, sampling policy, export, and process
context. `causationid` can be an application-owned context attribute, but it is
not part of W3C Trace Context.

Pass the Signal to `Jido.Signal.Telemetry.execute/4` when a custom telemetry
event must include its trace IDs and flags:

```elixir
Jido.Signal.Telemetry.execute(
  [:my_app, :signal, :handled],
  %{duration: duration},
  %{signal_type: signal.type},
  signal
)
```

This reads trace context from the Signal. It does not read process state.

## Dispatch Is Not Signal Metadata

Select a dispatch target at the delivery boundary:

```elixir
:ok = Jido.Signal.Dispatch.dispatch(signal, {:logger, level: :info})

{:ok, subscription_id} =
  Jido.Signal.Bus.subscribe(:events, "user.*", target: handler_pid)
```

This keeps transport state out of the core event data structure.
