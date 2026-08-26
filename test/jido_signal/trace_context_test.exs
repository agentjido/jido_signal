defmodule Jido.Signal.TraceContextTest do
  use ExUnit.Case, async: false

  alias Jido.Signal
  alias Jido.Signal.Trace
  alias Jido.Signal.Trace.Context
  alias Jido.Signal.TraceContext

  setup do
    TraceContext.clear()
    :ok
  end

  describe "current/0, set/1, clear/0" do
    test "current returns nil when no context set" do
      assert TraceContext.current() == nil
    end

    test "set stores context in process dictionary" do
      ctx = Context.new!()
      assert TraceContext.set(ctx) == :ok
      assert TraceContext.current() == ctx
    end

    test "clear removes context from process dictionary" do
      ctx = Context.new!()
      TraceContext.set(ctx)
      assert TraceContext.current() == ctx

      assert TraceContext.clear() == :ok
      assert TraceContext.current() == nil
    end

    test "set replaces existing context" do
      ctx1 = Context.new!()
      ctx2 = Context.new!()

      TraceContext.set(ctx1)
      TraceContext.set(ctx2)

      assert TraceContext.current() == ctx2
    end
  end

  describe "set_from_signal/1" do
    test "extracts and sets trace from signal" do
      {:ok, signal} = Signal.new("test.event", %{value: 1}, source: "/test")
      ctx = Trace.new_root()
      {:ok, traced} = Trace.put(signal, ctx)

      assert TraceContext.set_from_signal(traced) == :ok
      current = TraceContext.current()
      assert current.trace_id == ctx.trace_id
      assert current.span_id == ctx.span_id
    end

    test "returns :error when signal has no trace" do
      {:ok, signal} = Signal.new("test.event", %{value: 1}, source: "/test")

      assert TraceContext.set_from_signal(signal) == :error
      assert TraceContext.current() == nil
    end
  end

  describe "ensure_from_signal/1,2" do
    test "sets context from existing trace" do
      {:ok, signal} = Signal.new("test.event", %{value: 1}, source: "/test")
      ctx = Trace.new_root()
      {:ok, traced} = Trace.put(signal, ctx)

      {result_signal, result_ctx} = TraceContext.ensure_from_signal(traced)

      assert result_signal == traced
      assert result_ctx.trace_id == ctx.trace_id
      assert TraceContext.current() == result_ctx
    end

    test "creates root trace when signal has none" do
      {:ok, signal} = Signal.new("test.event", %{value: 1}, source: "/test")
      assert Trace.get(signal) == nil

      {traced_signal, ctx} = TraceContext.ensure_from_signal(signal)

      assert %Context{} = ctx
      assert Trace.get(traced_signal) != nil
      assert is_binary(ctx.trace_id)
      assert TraceContext.current() == ctx
    end

    test "accepts options for new root trace" do
      {:ok, signal} = Signal.new("test.event", %{value: 1}, source: "/test")

      {_signal, ctx} = TraceContext.ensure_from_signal(signal, causation_id: "req-123")

      assert ctx.causation_id == "req-123"
    end
  end

  describe "child_context/0,1" do
    test "creates child of current context" do
      parent = Trace.new_root()
      TraceContext.set(parent)

      child = TraceContext.child_context("signal-123")

      assert %Context{} = child
      assert child.trace_id == parent.trace_id
      assert child.parent_span_id == parent.span_id
      assert child.causation_id == "signal-123"
    end

    test "creates root when no current context" do
      TraceContext.clear()

      ctx = TraceContext.child_context("signal-123")

      assert %Context{} = ctx
      assert is_binary(ctx.trace_id)
      assert ctx.parent_span_id == nil
      assert ctx.causation_id == "signal-123"
    end

    test "handles nil causation_id" do
      parent = Trace.new_root()
      TraceContext.set(parent)

      child = TraceContext.child_context()

      assert child.causation_id == nil
    end
  end

  describe "propagate_to/1,2" do
    test "adds child trace to outbound signal" do
      parent = Trace.new_root()
      TraceContext.set(parent)

      {:ok, signal} = Signal.new("user.created", %{id: "123"}, source: "/test")
      {:ok, traced} = TraceContext.propagate_to(signal, "input-signal-id")

      ctx = Trace.get(traced)
      assert ctx.trace_id == parent.trace_id
      assert ctx.parent_span_id == parent.span_id
      assert ctx.causation_id == "input-signal-id"
    end

    test "creates root trace when no current context" do
      TraceContext.clear()

      {:ok, signal} = Signal.new("user.created", %{id: "123"}, source: "/test")
      {:ok, traced} = TraceContext.propagate_to(signal, "input-signal-id")

      ctx = Trace.get(traced)
      assert is_binary(ctx.trace_id)
      assert ctx.parent_span_id == nil
      assert ctx.causation_id == "input-signal-id"
    end
  end

  describe "to_telemetry_metadata/0,1" do
    test "returns prefixed metadata from current context" do
      ctx = %Context{
        trace_id: "abc123def456789012345678901234567",
        span_id: "def4567890123456",
        parent_span_id: "parent7890123456",
        causation_id: "signal-xyz"
      }

      TraceContext.set(ctx)

      meta = TraceContext.to_telemetry_metadata()

      assert meta.jido_trace_id == ctx.trace_id
      assert meta.jido_span_id == ctx.span_id
      assert meta.jido_parent_span_id == ctx.parent_span_id
      assert meta.jido_causation_id == ctx.causation_id
    end

    test "returns nil values when no context" do
      TraceContext.clear()

      meta = TraceContext.to_telemetry_metadata()

      assert meta.jido_trace_id == nil
      assert meta.jido_span_id == nil
      assert meta.jido_parent_span_id == nil
      assert meta.jido_causation_id == nil
    end

    test "handles context with missing optional fields" do
      ctx = Context.new!()
      TraceContext.set(ctx)

      meta = TraceContext.to_telemetry_metadata()

      assert meta.jido_trace_id == ctx.trace_id
      assert meta.jido_span_id == ctx.span_id
      assert meta.jido_parent_span_id == nil
      assert meta.jido_causation_id == nil
    end

    test "accepts explicit context argument" do
      ctx = Context.new!()

      meta = TraceContext.to_telemetry_metadata(ctx)

      assert meta.jido_trace_id == ctx.trace_id
    end

    test "accepts nil for explicit context" do
      meta = TraceContext.to_telemetry_metadata(nil)

      assert meta.jido_trace_id == nil
    end
  end

  describe "with_context/2 (signal)" do
    test "sets context during function execution" do
      {:ok, signal} = Signal.new("test.event", %{value: 1}, source: "/test")
      ctx = Trace.new_root()
      {:ok, traced} = Trace.put(signal, ctx)

      captured_ctx =
        TraceContext.with_context(traced, fn ->
          TraceContext.current()
        end)

      assert captured_ctx.trace_id == ctx.trace_id
    end

    test "clears context after function returns" do
      {:ok, signal} = Signal.new("test.event", %{value: 1}, source: "/test")
      ctx = Trace.new_root()
      {:ok, traced} = Trace.put(signal, ctx)

      TraceContext.with_context(traced, fn -> :ok end)

      assert TraceContext.current() == nil
    end

    test "clears context even if function raises" do
      {:ok, signal} = Signal.new("test.event", %{value: 1}, source: "/test")
      ctx = Trace.new_root()
      {:ok, traced} = Trace.put(signal, ctx)

      assert_raise RuntimeError, fn ->
        TraceContext.with_context(traced, fn ->
          raise "test error"
        end)
      end

      assert TraceContext.current() == nil
    end

    test "returns function result" do
      {:ok, signal} = Signal.new("test.event", %{value: 1}, source: "/test")
      ctx = Trace.new_root()
      {:ok, traced} = Trace.put(signal, ctx)

      result = TraceContext.with_context(traced, fn -> {:ok, 42} end)

      assert result == {:ok, 42}
    end
  end

  describe "with_context/2 (context)" do
    test "sets explicit context during function execution" do
      ctx = Context.new!()

      captured_ctx =
        TraceContext.with_context(ctx, fn ->
          TraceContext.current()
        end)

      assert captured_ctx == ctx
    end

    test "clears context after function returns" do
      ctx = Context.new!()

      TraceContext.with_context(ctx, fn -> :ok end)

      assert TraceContext.current() == nil
    end
  end

  describe "ensure_set_from_state/1" do
    test "extracts trace from state.current_signal" do
      {:ok, signal} = Signal.new("test.event", %{value: 1}, source: "/test")
      ctx = Trace.new_root()
      {:ok, traced} = Trace.put(signal, ctx)

      state = %{current_signal: traced, other: :data}

      assert TraceContext.ensure_set_from_state(state) == :ok
      current = TraceContext.current()
      assert current.trace_id == ctx.trace_id
      assert current.span_id == ctx.span_id
    end

    test "returns :error when signal has no trace" do
      {:ok, signal} = Signal.new("test.event", %{value: 1}, source: "/test")
      state = %{current_signal: signal}

      assert TraceContext.ensure_set_from_state(state) == :error
    end

    test "returns :ok for nil current_signal" do
      state = %{current_signal: nil}

      assert TraceContext.ensure_set_from_state(state) == :ok
    end

    test "returns :ok for missing current_signal" do
      state = %{other: :data}

      assert TraceContext.ensure_set_from_state(state) == :ok
    end
  end

  describe "process isolation" do
    test "context does not leak between processes" do
      ctx = Context.new!()
      TraceContext.set(ctx)

      task =
        Task.async(fn ->
          TraceContext.current()
        end)

      result = Task.await(task)

      assert result == nil
      assert TraceContext.current() == ctx
    end

    test "spawned process can set its own context" do
      parent_ctx = Context.new!()
      TraceContext.set(parent_ctx)

      task =
        Task.async(fn ->
          child_ctx = Context.new!()
          TraceContext.set(child_ctx)
          TraceContext.current()
        end)

      result = Task.await(task)

      assert result.trace_id != parent_ctx.trace_id
      assert TraceContext.current() == parent_ctx
    end
  end
end
