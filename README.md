# Jido.Signal

[![Hex.pm](https://img.shields.io/hexpm/v/jido_signal.svg)](https://hex.pm/packages/jido_signal)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/jido_signal/)
[![CI](https://github.com/agentjido/jido_signal/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jido_signal/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/jido_signal.svg)](https://github.com/agentjido/jido_signal/blob/main/LICENSE)
[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)
[![Ecosystem](https://img.shields.io/badge/ecosystem-jido.run-0ea5e9.svg)](https://jido.run/ecosystem)
[![Discord](https://img.shields.io/badge/discord-join-5865F2.svg?logo=discord&logoColor=white)](https://jido.run/discord)

> **Agent Communication Envelope and Utilities**

_`Jido.Signal` is part of the [Jido](https://github.com/agentjido/jido) project. Learn more about Jido at [jido.run](https://jido.run)._

The v3 public API has five primary areas: `Jido.Signal`,
`Jido.Signal.Serialization`, `Jido.Signal.Router`, `Jido.Signal.Dispatch`, and
`Jido.Signal.Bus`.

## Overview

`Jido.Signal` is a toolkit for event-driven and agent-based systems in Elixir. It provides a small CloudEvents 1.0 envelope, typed domain Signals, routing, dispatch, serialization, and a Signal Bus.

Whether you're building microservices that need reliable event communication, implementing complex agent-based systems, or creating observable distributed applications, Jido.Signal provides the foundation for robust, traceable, and scalable event-driven architecture.

## Why Do I Need Signals?

**Agent Communication in Elixir's Process-Driven World**

Elixir's strength lies in lightweight processes that communicate via message passing, but raw message passing has limitations when building complex systems:

- **Phoenix Channels** need structured event broadcasting across connections
- **GenServers** require reliable inter-process communication with context
- **Agent Systems** need stable message envelopes between autonomous processes
- **Distributed Services** need standardized message formats across nodes

Traditional Elixir messaging (`send`, `GenServer.cast/call`) works great for simple scenarios, but falls short when you need:

- **Standardized Message Format**: Raw tuples and maps lack structure and metadata
- **Event Routing**: Broadcasting to multiple interested processes based on patterns
- **Trace Context**: Keeping correlation data across process boundaries
- **Reliable Delivery**: Ensuring critical messages aren't lost if a process crashes
- **Cross-System Integration**: Communicating with external services via webhooks/HTTP

```elixir
# Traditional Elixir messaging
GenServer.cast(my_server, {:user_created, user_id, email})  # Unstructured
send(pid, {:event, data})  # No routing or reliability

# With Jido.Signal
{:ok, signal} = UserCreated.new(%{user_id: user_id, email: email})
Bus.publish(:app_bus, [signal])  # Structured, routed, traceable, reliable
```

Jido.Signal transforms Elixir's message passing into a sophisticated communication system that scales from simple GenServer interactions to complex multi-agent orchestration across distributed systems.

## Key Features

### **Standardized Signal Structure**
- CloudEvents 1.0 compliant message format
- UUID7 IDs for Signals created by Jido
- Explicit event source, time, and content type semantics
- Custom signal types with data validation
- Rich metadata and context tracking
- Flexible serialization (JSON, optional MessagePack, Erlang Term Format)

### **High-Performance Signal Bus**
- In-memory GenServer-based pub/sub system
- Persistent subscriptions with continuous checkpoints and a Dead Letter Queue (DLQ)
- Middleware pipeline for cross-cutting concerns with timeout protection
- Bounded replay through a Bus-owned Store boundary
- Application-owned retry, rate-limit, and workload-isolation policy
- Instance isolation for multi-tenant deployments

### **Advanced Routing Engine**
- Trie-based pattern matching for optimal performance
- Wildcard support (`*` single-level, `**` multi-level)
- Priority-based execution ordering
- Custom pattern matching functions

### **Pluggable Dispatch System**
- Multiple delivery adapters (PID, PubSub, HTTP, Logger, Console)
- Ordered synchronous delivery
- Zoi-validated target options
- Application-owned concurrency, retry, and circuit-breaking policy

## Installation

Add `jido_signal` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:jido_signal, "~> 3.0"}
  ]
end
```

If you use `:pubsub` dispatch, also add Phoenix.PubSub to your application:

```elixir
def deps do
  [
    {:jido_signal, "~> 3.0"},
    {:phoenix_pubsub, "~> 2.1"}
  ]
end
```

Then run:

```bash
mix deps.get
```

## Quick Start

### 1. Start a Signal Bus

Add to your application's supervision tree:

```elixir
# In your application.ex
children = [
  {Jido.Signal.Bus, name: :my_app_bus}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

### 2. Create a Subscriber

```elixir
defmodule MySubscriber do
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{})
  def init(state), do: {:ok, state}

  # Handle incoming signals
  def handle_info({:signal, signal}, state) do
    IO.puts("Received: #{signal.type}")
    {:noreply, state}
  end
end
```

### 3. Subscribe and Publish

```elixir
alias Jido.Signal.Bus
alias Jido.Signal

# Start subscriber and subscribe to user events
{:ok, sub_pid} = MySubscriber.start_link([])
{:ok, _sub_id} = Bus.subscribe(:my_app_bus, "user.*", dispatch: {:pid, target: sub_pid})

# Create and publish a signal
# Preferred: positional constructor (type, data, attrs)
{:ok, signal} = Signal.new("user.created", %{user_id: "123", email: "user@example.com"},
  source: "/auth/registration"
)

# Also available: Map/keyword constructor (backwards compatible)
{:ok, signal} = Signal.new(%{
  type: "user.created",
  source: "/auth/registration",
  data: %{user_id: "123", email: "user@example.com"}
})

Bus.publish(:my_app_bus, [signal])
# Output: "Received: user.created"
```

## Core Concepts

### The Signal

Signals are CloudEvents-compliant message envelopes that carry your application's events:

```elixir
# Basic signal with positional constructor (preferred)
{:ok, signal} = Signal.new("order.created", %{order_id: "ord_123", amount: 99.99},
  source: "/ecommerce/orders"
)

# Map constructor (also available)
{:ok, signal} = Signal.new(%{
  type: "order.created",
  source: "/ecommerce/orders",
  data: %{order_id: "ord_123", amount: 99.99}
})

# Dispatch is configured when subscribing or dispatching, not on the signal
:ok = Dispatch.dispatch(signal, [
  {:pubsub, target: MyApp.PubSub, topic: "payments"},
  {:webhook, url: "https://api.partner.com/webhook", secret: "secret123"}
])
```

### Custom Signal Types

Define strongly-typed signals with validation:

```elixir
defmodule UserCreated do
  use Jido.Signal,
    type: "user.created.v1",
    default_source: "/users",
    schema: Zoi.object(%{
      user_id: Zoi.string(),
      email: Zoi.string(),
      name: Zoi.string()
    })
end

# Usage
{:ok, signal} = UserCreated.new(%{
  user_id: "u_123",
  email: "john@example.com",
  name: "John Doe"
})

# Validation errors
{:error, reason} = UserCreated.new(%{user_id: "u_123"})
# reason identifies the missing email field.
```

Zoi is the schema format for custom Signals. Zoi schemas must accept and return
map-shaped data. Schemas must be static module data. Use named
`{Module, :function, args}` MFA values for refinements, transforms, and other
callbacks. Anonymous functions and lazy schemas are rejected at compile time.

CloudEvents extension context attributes are flat transport metadata. They are
optional and do not replace a custom Signal data schema:

```elixir
{:ok, signal} = Jido.Signal.put_context(signal, "tenantid", "tenant-123")
"tenant-123" = Jido.Signal.get_context(signal, "tenantid")
```

Context names use lower-case letters and digits. Values use CloudEvents context
types. Put domain data and dispatch policy outside this metadata map.

### The Router

Powerful pattern matching for signal routing:

```elixir
alias Jido.Signal.Router

routes = [
  # Exact matches have highest priority
  {"user.created", :handle_user_creation},
  
  # Single-level wildcards
  {"user.*.updated", :handle_user_updates},
  
  # Multi-level wildcards
  {"audit.**", :audit_logger, 100},  # High priority
  
  # Pattern matching functions
  {"**", fn signal -> String.contains?(signal.type, "error") end, :error_handler}
]

{:ok, router} = Router.new(routes)

# Route signals to handlers
{:ok, targets} = Router.route(router, Jido.Signal.new!("user.profile.updated", %{}))
# => {:ok, [:handle_user_updates]}
```

### Dispatch System

Flexible delivery to multiple destinations:

Dispatch is delivery infrastructure: it takes an existing signal and sends it to configured
destinations. In the wider Jido ecosystem, that does not mean every effect must be modeled as
signal dispatch. The broader boundary between pure agent logic, directives, and runtime execution
lives in Jido's [Core Loop](https://hexdocs.pm/jido/core-loop.html) and
[Actions](https://hexdocs.pm/jido/actions.html) guides.

```elixir
alias Jido.Signal.Dispatch

dispatch_configs = [
  # Send to process
  {:pid, target: my_process_pid},
  
  # Publish via Phoenix.PubSub
  # Requires {:phoenix_pubsub, "~> 2.1"} in your app deps.
  {:pubsub, target: MyApp.PubSub, topic: "events"},
  
  # HTTP webhook with signature
  {:webhook, url: "https://api.example.com/webhook", secret: "secret123"},
  
  # Log structured data
  {:logger, level: :info, structured: true},
  
  # Console output
  {:console, format: :pretty}
]

# Synchronous dispatch
:ok = Dispatch.dispatch(signal, dispatch_configs)
```

Dispatch is ordered and synchronous. Start a Task in the calling application if
delivery must run asynchronously. Retry and circuit-breaking policy also belongs
to the calling application or the Bus.

## Advanced Features

### Persistent Subscriptions

Track signal acknowledgments for reliable processing:

```elixir
# Create a persistent subscription
{:ok, sub_id} = Bus.subscribe(:my_app_bus, "payment.*",
  persistent?: true,
  start_from: :current,
  dispatch: {:pid, target: self()},
)

# Receive and acknowledge signals
{:ok, [_recorded]} = Bus.publish(:my_app_bus, [payment_signal])

receive do
  {:signal, ^payment_signal} ->
    process_payment(payment_signal)

    # A live consumer can acknowledge the delivered Signal ID.
    Bus.ack(:my_app_bus, sub_id, payment_signal.id)
end

# Reconnect a replacement target. Unacknowledged retained records are sent again.
{:ok, checkpoint} = Bus.reconnect(:my_app_bus, sub_id, replacement_pid)
```

The Bus does not retry delivery. A failed persistent delivery moves directly to
the DLQ. The consumer must be able to process duplicate delivery.

### Middleware Pipeline

Add cross-cutting concerns with middleware:

```elixir
middleware = [
  # Built-in logging middleware
  {Jido.Signal.Bus.Middleware.Logger, [
    level: :info,
    include_signal_data: true
  ]},
  
  # Custom middleware
  {MyApp.AuthMiddleware, []},
  {MyApp.MetricsMiddleware, []}
]

{:ok, _pid} = Jido.Signal.Bus.start_link(
  name: :my_bus, 
  middleware: middleware
)
```

Middleware callbacks (`before_publish`, `after_publish`, `before_dispatch`, `after_dispatch`) use timeout protection (default 100ms, configurable with `middleware_timeout_ms`). A `before_publish` timeout fails publication. A later callback timeout does not undo an already stored Signal. See `Jido.Signal.Bus.Middleware.Logger` for an example.

### Observability

Dispatch telemetry keeps the legacy `[:jido, :dispatch, :start|:stop|:exception]`
events with bounded metadata, and package execution logging defaults to
`config :jido_signal, default_log_level: :info`.

```elixir
config :jido_signal,
  default_log_level: :info

# Opt in to normalized dispatch errors during the compatibility transition.
config :jido_signal,
  normalize_dispatch_errors: true

{:error, error} = Jido.Signal.Dispatch.dispatch(signal, {:http, [url: "https://down.example.com"]})

Jido.Signal.Error.to_map(error)
# => %{
# =>   type: :dispatch_error,
# =>   message: "Signal dispatch failed",
# =>   details: %{"adapter" => "http", "reason" => "timeout"},
# =>   retryable?: true
# => }
```

### Retained Replay

Read the bounded Bus log:

```elixir
one_hour_ago = System.system_time(:millisecond) - 3_600_000

{:ok, records} =
  Bus.replay(:my_app_bus, "user.*", one_hour_ago, batch_size: 100)
```

The default memory Store keeps the newest 100,000 records and does not survive a
Bus restart. Set a custom `Jido.Signal.Bus.Store` implementation for restart
durability:

```elixir
{:ok, _bus} = Bus.start_link(
  name: :my_app_bus,
  store: MyApp.SignalStore,
  store_opts: [repo: MyApp.Repo]
)
```

### Instance Isolation

For multi-tenant applications or testing, create isolated signal infrastructure:

```elixir
# Start an isolated instance with its own Registry, TaskSupervisor, etc.
{:ok, _} = Jido.Signal.Instance.start_link(name: MyApp.Jido)

# Start buses scoped to the instance
{:ok, _} = Jido.Signal.Bus.start_link(name: :tenant_bus, jido: MyApp.Jido)

# Lookup uses the correct instance registry
{:ok, bus_pid} = Jido.Signal.Bus.whereis(:tenant_bus, jido: MyApp.Jido)

# Multiple instances are completely isolated
{:ok, _} = Jido.Signal.Instance.start_link(name: TenantA.Jido)
{:ok, _} = Jido.Signal.Instance.start_link(name: TenantB.Jido)

# Same bus name, different instances = different processes
{:ok, _} = Jido.Signal.Bus.start_link(name: :events, jido: TenantA.Jido)
{:ok, _} = Jido.Signal.Bus.start_link(name: :events, jido: TenantB.Jido)
```

## Use Cases

### Microservices Communication
```elixir
# Service A publishes order events
{:ok, signal} = OrderCreated.new(%{order_id: "123", customer_id: "456"})
Bus.publish(:event_bus, [signal])

# Service B processes inventory
# Service C sends notifications  
# Service D updates analytics
```

### Agent-Based Systems
```elixir
# Agents communicate via signals
{:ok, signal} = AgentMessage.new(%{
  from_agent: "agent_1",
  to_agent: "agent_2", 
  action: "negotiate_price",
  data: %{product_id: "prod_123", offered_price: 99.99}
})
```

### Event Sourcing
```elixir
# Commands become events
{:ok, command_signal} = CreateUser.new(user_data)
{:ok, event_signal} = UserCreated.new(user_data, cause: command_signal.id)

# Store the canonical map in the application event store.
MyApp.EventStore.append(Jido.Signal.to_map(event_signal))
```

### Distributed Workflows
```elixir
# Coordinate multi-step processes
workflow_signals = [
  %Signal{type: "workflow.started", data: %{workflow_id: "wf_123"}},
  %Signal{type: "step.completed", data: %{step: 1, workflow_id: "wf_123"}},
  %Signal{type: "step.completed", data: %{step: 2, workflow_id: "wf_123"}},
  %Signal{type: "workflow.completed", data: %{workflow_id: "wf_123"}}
]
```

## Documentation

- **[Getting Started Guide](guides/getting-started.md)** - Quick setup and first signal
- **[Signals & Dispatch](guides/signals-and-dispatch.md)** - Signal structure and dispatch adapters
- **[Event Bus](guides/event-bus.md)** - Pub/sub messaging with middleware
- **[Signal Router](guides/signal-router.md)** - Pattern matching and routing
- **[Signal Extensions](guides/signal-extensions.md)** - Custom Signal metadata extensions
- **[Serialization](guides/serialization.md)** - JSON, optional MessagePack, and Erlang Term formats
- **[Advanced Topics](guides/advanced.md)** - Custom adapters, performance, and testing
- **[v2 to v3 Migration](guides/v2-to-v3.md)** - Removed APIs and replacement patterns
- **[API Reference](https://hexdocs.pm/jido_signal)** - Complete function documentation

## Development

### Prerequisites

- Elixir 1.18+
- Erlang/OTP 27+

### Setup

```bash
git clone https://github.com/agentjido/jido_signal.git
cd jido_signal
mix deps.get
```

### Running Tests

```bash
mix test
```

### Quality Checks

```bash
mix quality  # Runs formatter, dialyzer, and credo
```

### Generate Documentation

```bash
mix docs
```

## Contributing

We welcome contributions! Please see our [Contributing Guide](CONTRIBUTING.md) for details on:

- Setting up your development environment
- Running tests and quality checks
- Submitting pull requests
- Code style guidelines

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Related Projects

- **[Jido](https://github.com/agentjido/jido)** - The main Jido agent framework
- **[Jido Workbench](https://github.com/agentjido/jido_workbench)** - Development tools and utilities

## Links

- [Hex Package](https://hex.pm/packages/jido_signal)
- [Documentation](https://hexdocs.pm/jido_signal)
- [GitHub Repository](https://github.com/agentjido/jido_signal)
- [Jido Website](https://jido.run)
- [Jido Ecosystem](https://jido.run/ecosystem)
- [Discord](https://jido.run/discord)
- [CloudEvents Specification](https://cloudevents.io/)

---

**Built with ❤️ by the Jido team**
