# Signal Extensions
<!-- covers: jido_signal.guides.signal_extensions -->

Signal extensions provide a way to add domain-specific metadata to Signals while maintaining CloudEvents v1.0.2 compliance. Extensions allow you to enrich Signals with custom functionality without modifying the core Signal structure.

## Why Extensions?

Extensions solve the problem of adding custom metadata to Signals:

- **Structured Metadata**: Type-safe, validated custom data
- **CloudEvents Compliance**: Extensions become top-level CloudEvents attributes
- **Composable**: Multiple extensions can work together on a single Signal
- **Backward Compatible**: Signals without extensions work unchanged

Common use cases include:
- **Threading**: Track conversation threads in LLM systems
- **Tracing**: Add distributed tracing context
- **Security**: Include authentication/authorization data
- **Routing**: Custom dispatch configurations

## Creating an Extension

Extensions are defined using the `Jido.Signal.Ext` behavior. Let's create a simple example:

```elixir
defmodule MyApp.Signal.Ext.Thread do
  @moduledoc """
  Extension for tracking conversation threads in LLM interactions.
  """
  
  use Jido.Signal.Ext,
    namespace: "thread",
    schema: Zoi.object(%{
      id: Zoi.string(description: "Unique thread identifier"),
      parent_id: Zoi.string(description: "Parent message ID for threading") |> Zoi.optional()
    })
end
```

That's it! The extension automatically:
- Registers itself in the extension registry
- Validates data using the schema
- Provides serialization to CloudEvents format
- Handles deserialization back to structured data

## Using Extensions

Add extension data to a Signal:

```elixir
# Create a Signal
{:ok, signal} = Jido.Signal.new("llm.conversation.message", 
  %{content: "Hello, how can I help?", role: "assistant"},
  source: "/chat/session"
)

# Add thread extension using namespace STRING
{:ok, signal_with_thread} = Jido.Signal.put_extension(signal, "thread", %{
  id: "thread-123",
  parent_id: "msg-456" 
})
```

Retrieve extension data:

```elixir
thread_data = Jido.Signal.get_extension(signal_with_thread, "thread")
# => %{id: "thread-123", parent_id: "msg-456"}

# Non-existent extension returns nil
missing = Jido.Signal.get_extension(signal_with_thread, "nonexistent")
# => nil
```

List all extensions on a Signal:

```elixir
extensions = Jido.Signal.list_extensions(signal_with_thread)
# => ["thread"]
```

Remove an extension:

```elixir
signal_without_thread = Jido.Signal.delete_extension(signal_with_thread, "thread")
```

## Built-in Dispatch Extension

Jido.Signal includes a built-in Dispatch extension for dispatch metadata. Prefer
passing a target directly to `Jido.Signal.Dispatch.dispatch/2` or in the options
for `Jido.Signal.Bus.subscribe/3`.

```elixir
# Add dispatch configuration via extension using namespace STRING
{:ok, signal} = Jido.Signal.put_extension(signal, "dispatch", 
  {:pubsub, topic: "chat-events"}
)

# Multiple dispatch targets
{:ok, signal} = Jido.Signal.put_extension(signal, "dispatch", [
  {:pubsub, topic: "events"},
  {:logger, level: :info}
])
```

## CloudEvents Serialization

Extensions automatically serialize to CloudEvents-compliant top-level attributes:

```elixir
# Signal with thread extension
signal = %Jido.Signal{
  type: "llm.conversation.message",
  source: "/chat",
  data: %{content: "Hello"},
  extensions: %{
    "thread" => %{id: "thread-123", parent_id: "msg-456"}
  }
}

# Serializes to CloudEvents JSON:
{:ok, json} = Jido.Signal.serialize(signal)
```

Results in:
```json
{
  "specversion": "1.0.2",
  "type": "llm.conversation.message", 
  "source": "/chat",
  "id": "...",
  "data": {"content": "Hello"},
  "threadid": "thread-123",
  "parentid": "msg-456"
}
```

## Custom Serialization

For more control over how extensions serialize, override the `to_attrs/1` and `from_attrs/1` callbacks:

```elixir
defmodule MyApp.Signal.Ext.CustomTrace do
  use Jido.Signal.Ext,
    namespace: "trace",
    schema: Zoi.object(%{
      trace_id: Zoi.string(),
      span_id: Zoi.string(),
      parent_span_id: Zoi.string() |> Zoi.optional()
    }),
    attributes: ["traceid", "spanid", "parentspan"]

  # Custom serialization - multiple CloudEvents attributes
  def to_attrs(%{trace_id: trace_id, span_id: span_id, parent_span_id: parent_span_id}) do
    attrs = %{
      "traceid" => trace_id,
      "spanid" => span_id
    }
    
    if parent_span_id do
      Map.put(attrs, "parentspan", parent_span_id)
    else
      attrs
    end
  end

  # Custom deserialization  
  def from_attrs(attrs) do
    case Map.get(attrs, "traceid") do
      nil -> nil
      trace_id ->
        %{
          trace_id: trace_id,
          span_id: Map.get(attrs, "spanid"),
          parent_span_id: Map.get(attrs, "parentspan")
        }
    end
  end
end
```

## Multiple Extensions

Signals can have multiple extensions simultaneously:

```elixir
{:ok, signal} = Jido.Signal.new("user.action", %{action: "login"})

# Add multiple extensions using namespace strings
{:ok, signal} = Jido.Signal.put_extension(signal, "thread", %{id: "session-123"})
{:ok, signal} = Jido.Signal.put_extension(signal, "trace", %{
  trace_id: "trace-abc", 
  span_id: "span-def"
})

# All extensions are preserved during serialization/deserialization
{:ok, json} = Jido.Signal.serialize(signal)
{:ok, deserialized_signal} = Jido.Signal.deserialize(json)

# Extensions are fully restored
thread_data = Jido.Signal.get_extension(deserialized_signal, "thread")
trace_data = Jido.Signal.get_extension(deserialized_signal, "trace")
```

## Extension Guidelines

### Namespace Rules
- Use lowercase names with optional dots (e.g., "auth", "trace", "auth.oauth")
- Keep names ≤ 20 characters (CloudEvents requirement)
- Only use `[a-z0-9]` characters (CloudEvents requirement)

### Schema Design

All package and application Signal schemas use Zoi.

- Use `Zoi.object/1` for map-shaped extension data.
- Object fields are required unless you use `Zoi.optional/1`.
- Add defaults with `Zoi.default/2` and descriptions with schema options.
- Keep data structures simple for serialization

### Example Patterns

**Authentication Context:**
```elixir
defmodule MyApp.Signal.Ext.Auth do
  use Jido.Signal.Ext,
    namespace: "auth",
    schema: Zoi.object(%{
      user_id: Zoi.string(),
      permissions: Zoi.array(Zoi.string()) |> Zoi.default([]),
      session_id: Zoi.string() |> Zoi.optional()
    })
end
```

**Metrics Collection:**
```elixir
defmodule MyApp.Signal.Ext.Metrics do
  use Jido.Signal.Ext,
    namespace: "metrics", 
    schema: Zoi.object(%{
      duration_ms: Zoi.integer() |> Zoi.optional(),
      memory_kb: Zoi.integer() |> Zoi.optional(),
      tags: Zoi.map() |> Zoi.default(%{})
    })
end
```

## Testing Extensions

Test extensions like any other module:

```elixir
defmodule MyApp.Signal.Ext.ThreadTest do
  use ExUnit.Case, async: true

  alias MyApp.Signal.Ext.Thread

  test "validates required fields" do
    assert {:ok, _} = Thread.new(%{id: "thread-123"})
    assert {:error, _} = Thread.new(%{parent_id: "msg-456"}) # missing id
  end

  test "serialization round-trip" do
    data = %{id: "thread-123", parent_id: "msg-456"}
    
    # Serialize
    attrs = Thread.to_attrs(data)
    
    # Deserialize  
    {:ok, restored_data} = Thread.from_attrs(attrs)
    
    assert data == restored_data
  end
end
```

## Error Handling and Safety

Jido Signal provides automatic error isolation for extensions to prevent corrupted extension data from affecting Signal processing.

The `put_extension/3` function returns `{:ok, signal}` on success or `{:error, reason}` if validation fails:

```elixir
# Successful extension data
{:ok, signal} = Jido.Signal.put_extension(signal, "thread", %{id: "thread-123"})

# Validation failure returns an error tuple
{:error, reason} = Jido.Signal.put_extension(signal, "thread", %{invalid: "data"})

# Unknown extension returns an error
{:error, "Unknown extension: unknown"} = Jido.Signal.put_extension(signal, "unknown", %{})
```

The `get_extension/2` function returns the data directly or `nil`:

```elixir
# Extension data or nil - no tuple wrapping
thread_data = Jido.Signal.get_extension(signal, "thread")
# => %{id: "thread-123"} or nil
```

The system uses "safe" wrapper functions internally that:
- Catch and wrap exceptions from extension callbacks
- Log warnings for unknown extensions during deserialization
- Preserve Signal integrity even when extensions fail
- Allow graceful degradation of functionality

## Unknown Extension Handling

When deserializing Signals with unknown extensions (extensions not registered in the current system), the serialization layer handles them gracefully:

```elixir
# Signal from external system with unknown "customext" extension
json = """
{
  "specversion": "1.0.2",
  "type": "user.action",
  "source": "/app",
  "customextdata": "some-value"
}
"""

# Deserialization succeeds - unknown attributes are preserved
{:ok, signal} = Jido.Signal.deserialize(json)

# Unknown extension data is preserved as raw attributes
signal.extensions
# => %{"_unknown" => %{"customextdata" => "some-value"}}
```

This is handled at the serialization/deserialization layer and ensures:
- Forward compatibility with future extensions
- Graceful handling of mixed-system environments
- Preservation of all CloudEvents data during round-trips

## Best Practices

1. **Keep Extensions Simple**: Focus on single responsibility
2. **Validate Early**: Use comprehensive schemas to catch errors
3. **Test Serialization**: Always test round-trip serialization
4. **Handle Errors Gracefully**: Extensions may fail - design for resilience
5. **Document Usage**: Provide clear examples in moduledocs
6. **Consider CloudEvents**: Ensure attribute names follow CloudEvents rules
7. **Backward Compatibility**: Design for evolution - avoid breaking changes
8. **Test Error Cases**: Verify your application handles extension failures

Extensions provide a powerful way to add domain-specific functionality to Signals while maintaining standardization and interoperability. The built-in error isolation ensures your system remains robust even when dealing with corrupted or unknown extension data, making them ideal for building sophisticated event-driven systems that scale from simple applications to complex distributed architectures.

## Next Steps

- [Event Bus](event-bus.md) - Publish, retain, and replay extended Signals
- [Serialization](serialization.md) - Convert signals to binary format for storage and transmission
