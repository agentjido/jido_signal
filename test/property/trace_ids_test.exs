Code.require_file("support/fuzz.exs", __DIR__)

defmodule JidoSignalTest.Property.TraceIDsTest do
  use ExUnit.Case, async: true
  import StreamData
  alias Jido.Signal
  alias Jido.Signal.{ID, Trace}
  alias JidoSignalTest.Property.Fuzz

  for {suite, runs} <- [property: 40, fuzz: 1000] do
    @tag [
      {suite, true},
      max_runs: runs,
      max_run_time: if(suite == :fuzz, do: 300_000, else: 10_000),
      timeout: if(suite == :fuzz, do: 900_000, else: 90_000)
    ]
    @tag contracts: ["TRACE-001", "ID-001"]
    @tag contract_cases: [
           "TRACE-001/carrier-lifecycle",
           "TRACE-001/invalid-carriers",
           "ID-001/byte-oracle",
           "ID-001/timestamp-extremes",
           "ID-001/invalid-shape"
         ]
    test "#{suite}: trace carriers and complete UUID7 values", context do
      generator =
        fixed_map(%{
          "timestamp" => integer(0..0xFFFFFFFFFFFF),
          "a" => integer(0..4095),
          "b" => integer(0..0x3FFFFFFFFFFFFFFF),
          "flags" => integer(0..255)
        })

      examples =
        for timestamp <- [0, 0xFFFFFFFFFFFF],
            a <- [0, 4095],
            b <- [0, 0x3FFFFFFFFFFFFFFF],
            do: %{"timestamp" => timestamp, "a" => a, "b" => b, "flags" => 255}

      Fuzz.check("trace_ids", generator, Map.to_list(context) ++ [examples: examples], &check/1)
    end
  end

  defp check(%{"timestamp" => t, "a" => a, "b" => b, "flags" => flags}) do
    raw = <<t::48, 7::4, a::12, 2::2, b::62>>
    other = <<t::48, 7::4, 0::12, 2::2, 0::62>>
    uuid = uuid(raw)
    assert ID.valid?(uuid)
    assert ID.valid?(String.upcase(uuid))
    assert ID.extract_timestamp(uuid) == t

    expected =
      cond do
        raw < other -> :lt
        raw > other -> :gt
        true -> :eq
      end

    assert ID.compare(uuid, uuid(other)) == expected
    assert ID.compare(uuid, String.upcase(uuid)) == :eq

    for bad <- [
          uuid <> "\n",
          uuid(<<t::48, 4::4, a::12, 2::2, b::62>>),
          "",
          nil,
          "not-an-id"
        ] do
      refute ID.valid?(bad)
    end

    variant = <<t::48, 7::4, a::12, 0::2, b::62>>
    refute ID.valid?(uuid(variant))
    assert_raise ArgumentError, fn -> ID.extract_timestamp(uuid(variant)) end
    {generated, timestamp} = ID.generate()
    assert ID.valid?(generated)
    assert ID.extract_timestamp(generated) == timestamp

    trace_id = Base.encode16(<<t + 1::128>>, case: :lower)
    span_id = Base.encode16(<<b + 1::64>>, case: :lower)
    flag_text = Base.encode16(<<flags>>, case: :lower)
    carrier = "00-#{trace_id}-#{span_id}-#{flag_text}"
    assert {:ok, trace} = Trace.from_traceparent(carrier, "tenant=one,other=two")
    assert Trace.to_traceparent(trace) == carrier
    child = Trace.child(trace)
    assert child.trace_id == trace_id and child.trace_flags == flag_text
    assert child.tracestate == trace.tracestate
    assert child.span_id != span_id
    assert Trace.valid?(child)
    root = Trace.new(trace_flags: flag_text)
    assert Trace.valid?(root)
    signal = Signal.new!("trace.event", %{}, source: "/property")
    assert {:ok, traced} = Trace.put(signal, trace)
    assert Trace.get(traced) == trace
    assert {:ok, ^traced, ^trace} = Trace.ensure(traced)

    for format <- [:json, :erlang_term] do
      assert {:ok, binary} = Signal.serialize(traced, format: format)
      assert {:ok, parsed} = Signal.deserialize(binary, format: format)
      assert Trace.get(parsed) == trace
    end

    assert Trace.get(Trace.delete(traced)) == nil
    assert Trace.delete(traced).extensions == %{}
    assert {:ok, new_signal, new_trace} = Trace.ensure(signal)
    assert Trace.get(new_signal) == new_trace

    for invalid <- [
          carrier <> "\n",
          String.upcase(carrier),
          "01-#{trace_id}-#{span_id}-#{flag_text}",
          "00-#{String.duplicate("0", 32)}-#{span_id}-00",
          "00-#{trace_id}-#{String.duplicate("0", 16)}-00"
        ] do
      # An all-digit carrier is unchanged by uppercase conversion.
      if invalid != carrier do
        assert {:error, :invalid_traceparent} = Trace.from_traceparent(invalid)
      end
    end

    for state <- ["tenant=one,tenant=two", "Bad=x", "a=" <> String.duplicate("x", 513)] do
      assert {:error, _} = Trace.put(signal, %{trace | tracestate: state})
      assert {:ok, %{tracestate: nil}} = Trace.from_traceparent(carrier, state)
    end

    ["uuid-comparison-#{expected}", "flags-#{flag_text}"]
  end

  defp uuid(raw) do
    hex = Base.encode16(raw, case: :lower)

    [
      String.slice(hex, 0, 8),
      String.slice(hex, 8, 4),
      String.slice(hex, 12, 4),
      String.slice(hex, 16, 4),
      String.slice(hex, 20, 12)
    ]
    |> Enum.join("-")
  end
end
