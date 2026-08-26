defmodule Jido.Signal.Serialization do
  @moduledoc """
  Encodes and decodes Signals through one canonical map contract.

  All built-in formats call `Jido.Signal.to_map/1` before encoding and
  `Jido.Signal.from_map/1` after decoding. JSON is the default. MessagePack is
  optional. Erlang term encoding is available for trusted Erlang systems.

  Use the `:serializer` option to select a module that implements
  `Jido.Signal.Serialization.Serializer`.
  """

  alias Jido.Signal
  alias Jido.Signal.Serialization.Serializer

  @doc "Encodes one Signal or a list of Signals."
  @spec serialize(Signal.t() | [Signal.t()], keyword()) ::
          {:ok, binary()} | {:error, term()}
  def serialize(signal_or_signals, opts \\ []) do
    Serializer.serialize(signal_or_signals, opts)
  end

  @doc "Decodes one Signal or a list of Signals."
  @spec deserialize(binary(), keyword()) ::
          {:ok, Signal.t() | [Signal.t()]} | {:error, term()}
  def deserialize(binary, opts \\ []) when is_binary(binary) do
    with {:ok, data} <- Serializer.deserialize(binary, opts) do
      convert(data)
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp convert(data) when is_list(data) do
    data
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case convert_one(item) do
        {:ok, signal} -> {:cont, {:ok, [signal | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, signals} -> {:ok, Enum.reverse(signals)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp convert(data), do: convert_one(data)

  defp convert_one(%Signal{} = signal), do: {:ok, signal}
  defp convert_one(data) when is_map(data), do: Signal.from_map(data)
  defp convert_one(data), do: {:error, "cannot convert #{inspect(data)} to Signal"}
end
