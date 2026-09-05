defmodule Jido.Signal.Serialization do
  @moduledoc """
  Encodes and decodes Signals through the canonical CloudEvents map.

  JSON is the default format. Use `format: :erlang_term` for trusted
  Erlang/Elixir systems.

  The maximum encoded or decoded payload size is 10 MB. Set
  `:max_payload_bytes` for one call, or configure `:max_payload_bytes` for the
  `:jido_signal` application.
  """

  alias Jido.Signal

  @default_max_payload_bytes 10_000_000

  @type format :: :json | :erlang_term

  @doc "Encodes one Signal or a list of Signals."
  @spec serialize(Signal.t() | [Signal.t()], keyword()) ::
          {:ok, binary()} | {:error, term()}
  def serialize(signal_or_signals, opts \\ [])

  def serialize(signal_or_signals, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      do_serialize(signal_or_signals, opts)
    else
      {:error, {:invalid_options, "expected a keyword list"}}
    end
  end

  def serialize(_signal_or_signals, _opts),
    do: {:error, {:invalid_options, "expected a keyword list"}}

  defp do_serialize(signal_or_signals, opts) do
    with {:ok, format} <- format(opts),
         {:ok, wire_data} <- to_wire_data(signal_or_signals),
         {:ok, binary} <- encode(wire_data, format),
         :ok <- check_payload_size(binary, opts) do
      {:ok, binary}
    end
  rescue
    exception -> {:error, {:serialization_failed, Exception.message(exception)}}
  end

  @doc "Decodes one Signal or a list of Signals."
  @spec deserialize(binary(), keyword()) ::
          {:ok, Signal.t() | [Signal.t()]} | {:error, term()}
  def deserialize(binary, opts \\ [])

  def deserialize(binary, opts) when is_binary(binary) and is_list(opts) do
    if Keyword.keyword?(opts) do
      with {:ok, format} <- format(opts),
           :ok <- check_payload_size(binary, opts),
           {:ok, wire_data} <- decode(binary, format),
           :ok <- check_decoded_size(wire_data, format, opts) do
        from_wire_data(wire_data)
      end
    else
      {:error, {:invalid_options, "expected a keyword list"}}
    end
  rescue
    exception -> {:error, {:deserialization_failed, Exception.message(exception)}}
  end

  def deserialize(binary, _opts) when not is_binary(binary),
    do: {:error, {:invalid_payload, "expected a binary"}}

  def deserialize(_binary, _opts), do: {:error, {:invalid_options, "expected a keyword list"}}

  defp to_wire_data(%Signal{} = signal), do: {:ok, Signal.to_map(signal)}

  defp to_wire_data(signals) when is_list(signals) do
    signals
    |> Enum.reduce_while({:ok, []}, fn
      %Signal{} = signal, {:ok, acc} ->
        {:cont, {:ok, [Signal.to_map(signal) | acc]}}

      value, _acc ->
        {:halt, {:error, {:invalid_signal, "expected a Signal, got: #{inspect(value)}"}}}
    end)
    |> case do
      {:ok, wire_data} -> {:ok, Enum.reverse(wire_data)}
      error -> error
    end
  end

  defp to_wire_data(value),
    do:
      {:error, {:invalid_signal, "expected a Signal or list of Signals, got: #{inspect(value)}"}}

  defp from_wire_data(data) when is_list(data) do
    data
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case from_wire_item(item) do
        {:ok, signal} -> {:cont, {:ok, [signal | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, signals} -> {:ok, Enum.reverse(signals)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp from_wire_data(data), do: from_wire_item(data)

  defp from_wire_item(data) when is_map(data), do: Signal.from_map(data)

  defp from_wire_item(data),
    do: {:error, {:invalid_wire_data, "expected a map, got: #{inspect(data)}"}}

  defp format(opts) do
    case Keyword.get(opts, :format, :json) do
      format when format in [:json, :erlang_term] -> {:ok, format}
      format -> {:error, {:unsupported_format, format}}
    end
  end

  defp encode(data, :json) do
    if json_value?(data) do
      case Jason.encode(data) do
        {:ok, binary} -> {:ok, binary}
        {:error, error} -> {:error, {:json_encode_failed, Exception.message(error)}}
      end
    else
      {:error, {:json_encode_failed, "Signal data must contain JSON values or binary data"}}
    end
  end

  defp encode(data, :erlang_term), do: {:ok, :erlang.term_to_binary(data)}

  defp decode(binary, :json) do
    case Jason.decode(binary) do
      {:ok, data} -> {:ok, data}
      {:error, error} -> {:error, {:json_decode_failed, Exception.message(error)}}
    end
  end

  defp decode(binary, :erlang_term) do
    case binary do
      <<131, 80, _rest::binary>> ->
        {:error, {:erlang_term_decode_failed, "compressed Erlang terms are not accepted"}}

      _uncompressed ->
        {:ok, :erlang.binary_to_term(binary, [:safe])}
    end
  rescue
    error in ArgumentError -> {:error, {:erlang_term_decode_failed, Exception.message(error)}}
  end

  defp check_payload_size(binary, opts) do
    max =
      Keyword.get_lazy(opts, :max_payload_bytes, fn ->
        Application.get_env(:jido_signal, :max_payload_bytes, @default_max_payload_bytes)
      end)

    if is_integer(max) and max >= 0 do
      if byte_size(binary) <= max do
        :ok
      else
        {:error, {:payload_too_large, byte_size(binary), max}}
      end
    else
      {:error, {:invalid_max_payload_bytes, max}}
    end
  end

  defp check_decoded_size(_wire_data, :json, _opts), do: :ok

  defp check_decoded_size(wire_data, :erlang_term, opts) do
    wire_data
    |> :erlang.term_to_binary()
    |> check_payload_size(opts)
  end

  defp json_value?(nil), do: true
  defp json_value?(value) when is_boolean(value) or is_number(value), do: true
  defp json_value?(value) when is_binary(value), do: Jido.Signal.UTF8.valid?(value)
  defp json_value?([]), do: true
  defp json_value?([head | tail]) when is_list(tail), do: json_value?(head) and json_value?(tail)

  defp json_value?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {key, item} ->
      is_binary(key) and String.valid?(key) and json_value?(item)
    end)
  end

  defp json_value?(_value), do: false
end
