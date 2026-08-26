defmodule Jido.Signal.Trace do
  @moduledoc """
  Carries W3C trace context on Signals.

  A Trace contains the current trace ID, span ID, trace flags, and optional
  `tracestate`. Signals store it in the flat `traceparent` and `tracestate`
  CloudEvents context attributes.

  This module can create root and child trace values. A full tracing system,
  such as OpenTelemetry, still owns span lifetime, sampling policy, export, and
  process context.
  """

  alias Jido.Signal
  alias Jido.Signal.Context, as: SignalContext

  @trace_id_bytes 16
  @span_id_bytes 8
  @traceparent "traceparent"
  @tracestate "tracestate"
  @traceparent_pattern ~r/\A00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})\z/

  @schema Zoi.struct(
            __MODULE__,
            %{
              trace_id:
                Zoi.string()
                |> Zoi.refine({__MODULE__, :validate_trace_id, []}),
              span_id:
                Zoi.string()
                |> Zoi.refine({__MODULE__, :validate_span_id, []}),
              trace_flags:
                Zoi.string()
                |> Zoi.refine({__MODULE__, :validate_trace_flags, []}),
              tracestate:
                Zoi.string()
                |> Zoi.refine({__MODULE__, :validate_tracestate, []})
                |> Zoi.nullable()
                |> Zoi.optional()
            }
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a Trace value."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Creates a new root Trace."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    validate_options!(opts)

    build!(%__MODULE__{
      trace_id: generate_id(@trace_id_bytes),
      span_id: generate_id(@span_id_bytes),
      trace_flags: Keyword.get(opts, :trace_flags, "00"),
      tracestate: Keyword.get(opts, :tracestate)
    })
  end

  @doc "Creates a child Trace with a new span ID."
  @spec child(t()) :: t()
  def child(%__MODULE__{} = parent) do
    if valid?(parent) do
      %__MODULE__{
        trace_id: parent.trace_id,
        span_id: generate_id(@span_id_bytes),
        trace_flags: parent.trace_flags,
        tracestate: parent.tracestate
      }
    else
      raise ArgumentError, "invalid parent Trace"
    end
  end

  @doc "Parses a W3C version 00 traceparent value."
  @spec from_traceparent(String.t(), String.t() | nil) ::
          {:ok, t()} | {:error, :invalid_traceparent}
  def from_traceparent(traceparent, tracestate \\ nil)

  def from_traceparent(traceparent, tracestate) when is_binary(traceparent) do
    with [_, trace_id, span_id, trace_flags] <- Regex.run(@traceparent_pattern, traceparent),
         {:ok, trace} <-
           parse(%__MODULE__{
             trace_id: trace_id,
             span_id: span_id,
             trace_flags: trace_flags,
             tracestate: normalize_tracestate(tracestate)
           }) do
      {:ok, trace}
    else
      _invalid -> {:error, :invalid_traceparent}
    end
  end

  def from_traceparent(_traceparent, _tracestate), do: {:error, :invalid_traceparent}

  @doc "Formats a Trace as a W3C version 00 traceparent value."
  @spec to_traceparent(t()) :: String.t()
  def to_traceparent(%__MODULE__{} = trace) do
    if valid?(trace) do
      "00-#{trace.trace_id}-#{trace.span_id}-#{trace.trace_flags}"
    else
      raise ArgumentError, "invalid Trace"
    end
  end

  @doc "Gets the valid Trace carried by a Signal."
  @spec get(Signal.t()) :: t() | nil
  def get(%Signal{} = signal) do
    case Signal.get_context(signal, @traceparent) do
      traceparent when is_binary(traceparent) ->
        case from_traceparent(traceparent, Signal.get_context(signal, @tracestate)) do
          {:ok, trace} -> trace
          {:error, :invalid_traceparent} -> nil
        end

      _missing ->
        nil
    end
  end

  def get(_signal), do: nil

  @doc "Puts a valid Trace on a Signal."
  @spec put(Signal.t(), t()) :: {:ok, Signal.t()} | {:error, String.t()}
  def put(%Signal{} = signal, %__MODULE__{} = trace) do
    case parse(trace) do
      {:ok, trace} ->
        attributes =
          %{
            @traceparent => to_traceparent(trace),
            @tracestate => trace.tracestate
          }
          |> Map.reject(fn {_name, value} -> is_nil(value) end)

        with {:ok, attributes} <- SignalContext.normalize(attributes) do
          signal = delete(signal)
          {:ok, %{signal | extensions: Map.merge(signal.extensions, attributes)}}
        end

      {:error, errors} ->
        {:error, "invalid Trace: #{Zoi.prettify_errors(errors)}"}
    end
  end

  def put(_signal, _trace), do: {:error, "expected a Signal and Trace"}

  @doc "Deletes traceparent and tracestate from a Signal."
  @spec delete(Signal.t()) :: Signal.t()
  def delete(%Signal{} = signal) do
    signal
    |> Signal.delete_context(@traceparent)
    |> Signal.delete_context(@tracestate)
  end

  @doc "Returns the Signal trace, or creates and stores a new root Trace."
  @spec ensure(Signal.t(), keyword()) :: {:ok, Signal.t(), t()} | {:error, String.t()}
  def ensure(%Signal{} = signal, opts \\ []) do
    case get(signal) do
      %__MODULE__{} = trace -> {:ok, signal, trace}
      nil -> put_new_trace(signal, new(opts))
    end
  end

  @doc "Checks a Trace struct or traceparent string."
  @spec valid?(t() | String.t() | term()) :: boolean()
  def valid?(%__MODULE__{} = trace), do: match?({:ok, _trace}, parse(trace))

  def valid?(traceparent) when is_binary(traceparent),
    do: match?({:ok, _}, from_traceparent(traceparent))

  def valid?(_value), do: false

  @doc false
  def validate_trace_id(value, _opts), do: validate_id(value, 32, "trace ID")

  @doc false
  def validate_span_id(value, _opts), do: validate_id(value, 16, "span ID")

  @doc false
  def validate_trace_flags(value, _opts) do
    if value in ["00", "01"] do
      :ok
    else
      {:error, "version 00 trace flags must be 00 or 01"}
    end
  end

  @doc false
  def validate_tracestate(value, _opts) do
    if is_binary(value) and String.valid?(value) and byte_size(value) <= 512 do
      :ok
    else
      {:error, "tracestate must be a valid UTF-8 string with at most 512 bytes"}
    end
  end

  defp put_new_trace(signal, trace) do
    case put(signal, trace) do
      {:ok, traced} -> {:ok, traced, trace}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse(trace), do: Zoi.parse(@schema, trace)

  defp build!(trace) do
    case parse(trace) do
      {:ok, trace} -> trace
      {:error, errors} -> raise ArgumentError, Zoi.prettify_errors(errors)
    end
  end

  defp validate_options!(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:trace_flags, :tracestate] == [] do
      :ok
    else
      raise ArgumentError, "expected trace_flags and tracestate options"
    end
  end

  defp normalize_tracestate(nil), do: nil

  defp normalize_tracestate(tracestate) do
    case validate_tracestate(tracestate, []) do
      :ok -> tracestate
      {:error, _reason} -> nil
    end
  end

  defp validate_id(value, size, name) do
    zero = String.duplicate("0", size)
    pattern = ~r/\A[0-9a-f]{#{size}}\z/

    if is_binary(value) and value != zero and Regex.match?(pattern, value) do
      :ok
    else
      {:error, "#{name} must be #{size} lower-case hexadecimal characters and not all zero"}
    end
  end

  defp generate_id(bytes) do
    id = bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    if String.trim(id, "0") == "", do: generate_id(bytes), else: id
  end
end
