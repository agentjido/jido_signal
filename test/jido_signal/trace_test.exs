defmodule Jido.Signal.TraceTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Trace
  alias Jido.Signal.Trace.Context

  describe "new_root/0,1" do
    test "generates valid W3C trace_id (32 hex chars)" do
      ctx = Trace.new_root()
      assert %Context{} = ctx
      assert is_binary(ctx.trace_id)
      assert byte_size(ctx.trace_id) == 32
      assert String.match?(ctx.trace_id, ~r/^[0-9a-f]+$/)
    end

    test "generates valid W3C span_id (16 hex chars)" do
      ctx = Trace.new_root()
      assert is_binary(ctx.span_id)
      assert byte_size(ctx.span_id) == 16
      assert String.match?(ctx.span_id, ~r/^[0-9a-f]+$/)
    end

    test "sets parent_span_id to nil for root" do
      ctx = Trace.new_root()
      assert ctx.parent_span_id == nil
    end

    test "generates unique IDs on each call" do
      ctx1 = Trace.new_root()
      ctx2 = Trace.new_root()
      assert ctx1.trace_id != ctx2.trace_id
      assert ctx1.span_id != ctx2.span_id
    end

    test "accepts causation_id option" do
      ctx = Trace.new_root(causation_id: "external-request-123")
      assert ctx.causation_id == "external-request-123"
    end

    test "accepts tracestate option" do
      ctx = Trace.new_root(tracestate: "vendor1=value1,vendor2=value2")
      assert ctx.tracestate == "vendor1=value1,vendor2=value2"
    end
  end

  describe "child_of/2" do
    test "shares parent trace_id" do
      parent = Trace.new_root()
      child = Trace.child_of(parent, "signal-123")
      assert child.trace_id == parent.trace_id
    end

    test "generates new span_id for child" do
      parent = Trace.new_root()
      child = Trace.child_of(parent, "signal-123")
      assert child.span_id != parent.span_id
      assert byte_size(child.span_id) == 16
    end

    test "sets parent_span_id to parent's span_id" do
      parent = Trace.new_root()
      child = Trace.child_of(parent, "signal-123")
      assert child.parent_span_id == parent.span_id
    end

    test "sets causation_id to the given value" do
      parent = Trace.new_root()
      child = Trace.child_of(parent, "signal-123")
      assert child.causation_id == "signal-123"
    end

    test "inherits tracestate from parent" do
      parent = Trace.new_root(tracestate: "vendor=value")
      child = Trace.child_of(parent, "signal-123")
      assert child.tracestate == "vendor=value"
    end

    test "handles nil parent by creating root" do
      child = Trace.child_of(nil, "signal-123")
      assert is_binary(child.trace_id)
      assert is_binary(child.span_id)
      assert child.parent_span_id == nil
      assert child.causation_id == "signal-123"
    end

    test "handles nil causation_id" do
      parent = Trace.new_root()
      child = Trace.child_of(parent, nil)
      assert child.causation_id == nil
    end
  end

  describe "get/1 and put/2" do
    test "put adds trace to signal extensions" do
      {:ok, signal} = Signal.new("test.event", %{value: 1}, source: "/test")
      ctx = Trace.new_root()

      {:ok, traced} = Trace.put(signal, ctx)

      assert traced.extensions["traceparent"] == Trace.to_traceparent(ctx)
    end

    test "get extracts trace from signal extensions" do
      {:ok, signal} = Signal.new("test.event", %{value: 1}, source: "/test")
      ctx = Trace.new_root()
      {:ok, traced} = Trace.put(signal, ctx)

      retrieved = Trace.get(traced)

      assert %Context{} = retrieved
      assert retrieved.trace_id == ctx.trace_id
      assert retrieved.span_id == ctx.span_id
    end

    test "get returns nil for signal without trace" do
      {:ok, signal} = Signal.new("test.event", %{value: 1}, source: "/test")
      assert Trace.get(signal) == nil
    end

    test "get returns nil for non-signal input" do
      assert Trace.get("not a signal") == nil
      assert Trace.get(nil) == nil
    end

    test "roundtrip preserves all fields" do
      {:ok, signal} = Signal.new("test.event", %{value: 1}, source: "/test")

      ctx = %Context{
        trace_id: "4bf92f3577b34da6a3ce929d0e0e4736",
        span_id: "00f067aa0ba902b7",
        parent_span_id: "abcdef0123456789",
        causation_id: "signal-xyz",
        tracestate: "vendor=value"
      }

      {:ok, traced} = Trace.put(signal, ctx)
      retrieved = Trace.get(traced)

      assert retrieved.trace_id == ctx.trace_id
      assert retrieved.span_id == ctx.span_id
      assert retrieved.parent_span_id == ctx.parent_span_id
      assert retrieved.causation_id == ctx.causation_id
      assert retrieved.tracestate == ctx.tracestate
    end
  end

  describe "put!/2" do
    test "returns signal on success" do
      {:ok, signal} = Signal.new("test.event", %{value: 1}, source: "/test")
      ctx = Trace.new_root()

      traced = Trace.put!(signal, ctx)

      assert traced.extensions["traceparent"] == Trace.to_traceparent(ctx)
    end
  end

  describe "ensure/1,2" do
    test "adds root trace when signal has none" do
      {:ok, signal} = Signal.new("test.event", %{value: 1}, source: "/test")
      assert Trace.get(signal) == nil

      {:ok, traced, ctx} = Trace.ensure(signal)

      assert %Context{} = ctx
      stored = Trace.get(traced)
      assert stored.trace_id == ctx.trace_id
      assert stored.span_id == ctx.span_id
      assert is_binary(ctx.trace_id)
      assert is_binary(ctx.span_id)
    end

    test "preserves existing trace" do
      {:ok, signal} = Signal.new("test.event", %{value: 1}, source: "/test")
      original_ctx = Trace.new_root()
      {:ok, traced} = Trace.put(signal, original_ctx)

      {:ok, result, ctx} = Trace.ensure(traced)

      assert result == traced
      assert ctx.trace_id == original_ctx.trace_id
      assert ctx.span_id == original_ctx.span_id
    end

    test "accepts causation_id option for new trace" do
      {:ok, signal} = Signal.new("test.event", %{value: 1}, source: "/test")

      {:ok, _traced, ctx} = Trace.ensure(signal, causation_id: "external-123")

      assert ctx.causation_id == "external-123"
    end
  end

  describe "to_traceparent/1" do
    test "formats as W3C traceparent" do
      ctx = %Context{
        trace_id: "4bf92f3577b34da6a3ce929d0e0e4736",
        span_id: "00f067aa0ba902b7"
      }

      traceparent = Trace.to_traceparent(ctx)

      assert traceparent == "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    end

    test "uses version 00 and sampled flag 01" do
      ctx = Trace.new_root()
      traceparent = Trace.to_traceparent(ctx)

      [version, _trace_id, _span_id, flags] = String.split(traceparent, "-")
      assert version == "00"
      assert flags == "01"
    end
  end

  describe "from_traceparent/1" do
    test "parses valid traceparent" do
      traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

      ctx = Trace.from_traceparent(traceparent)

      assert %Context{} = ctx
      assert ctx.trace_id == "4bf92f3577b34da6a3ce929d0e0e4736"
      assert ctx.span_id == "00f067aa0ba902b7"
      assert ctx.parent_span_id == nil
      assert ctx.causation_id == nil
    end

    test "returns nil for invalid format" do
      assert Trace.from_traceparent("invalid") == nil
      assert Trace.from_traceparent("") == nil
      assert Trace.from_traceparent(nil) == nil
    end

    test "returns nil for wrong trace_id length" do
      assert Trace.from_traceparent("00-short-00f067aa0ba902b7-01") == nil
    end

    test "returns nil for wrong span_id length" do
      assert Trace.from_traceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-short-01") == nil
    end

    test "returns nil for non-hex characters" do
      assert Trace.from_traceparent("00-GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG-00f067aa0ba902b7-01") ==
               nil
    end

    test "roundtrip with to_traceparent" do
      ctx = Trace.new_root()
      traceparent = Trace.to_traceparent(ctx)
      parsed = Trace.from_traceparent(traceparent)

      assert parsed.trace_id == ctx.trace_id
      assert parsed.span_id == ctx.span_id
    end
  end

  describe "child_from_traceparent/2" do
    test "creates child span from traceparent" do
      traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

      child = Trace.child_from_traceparent(traceparent, causation_id: "req-123")

      assert %Context{} = child
      assert child.trace_id == "4bf92f3577b34da6a3ce929d0e0e4736"
      assert child.parent_span_id == "00f067aa0ba902b7"
      assert child.span_id != "00f067aa0ba902b7"
      assert byte_size(child.span_id) == 16
      assert child.causation_id == "req-123"
    end

    test "returns nil for invalid traceparent" do
      assert Trace.child_from_traceparent("invalid") == nil
    end

    test "accepts tracestate option" do
      traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

      child = Trace.child_from_traceparent(traceparent, tracestate: "vendor=value")

      assert child.tracestate == "vendor=value"
    end
  end

  describe "valid?/1" do
    test "returns true for valid context" do
      ctx = Trace.new_root()
      assert Trace.valid?(ctx) == true
    end

    test "returns false for nil" do
      assert Trace.valid?(nil) == false
    end

    test "returns false for invalid trace_id length" do
      ctx = %Context{trace_id: "short", span_id: "00f067aa0ba902b7"}
      assert Trace.valid?(ctx) == false
    end

    test "returns false for invalid span_id length" do
      ctx = %Context{trace_id: "4bf92f3577b34da6a3ce929d0e0e4736", span_id: "short"}
      assert Trace.valid?(ctx) == false
    end

    test "returns false for non-hex trace_id" do
      ctx = %Context{trace_id: "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG", span_id: "00f067aa0ba902b7"}
      assert Trace.valid?(ctx) == false
    end
  end

  describe "integration with Signal serialization" do
    test "trace survives signal JSON serialization roundtrip" do
      {:ok, signal} = Signal.new("test.event", %{value: 1}, source: "/test")
      ctx = Trace.new_root()
      {:ok, traced} = Trace.put(signal, ctx)

      {:ok, json} = Signal.serialize(traced)
      {:ok, restored} = Signal.deserialize(json)

      restored_ctx = Trace.get(restored)
      assert restored_ctx.trace_id == ctx.trace_id
      assert restored_ctx.span_id == ctx.span_id
    end
  end
end
