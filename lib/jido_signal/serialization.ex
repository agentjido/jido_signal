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

  @doc "Encodes one Signal or a list of Signals."
  @spec serialize(Signal.t() | [Signal.t()], keyword()) ::
          {:ok, binary()} | {:error, term()}
  def serialize(signal_or_signals, opts \\ []) do
    Signal.serialize(signal_or_signals, opts)
  end

  @doc "Decodes one Signal or a list of Signals."
  @spec deserialize(binary(), keyword()) ::
          {:ok, Signal.t() | [Signal.t()]} | {:error, term()}
  def deserialize(binary, opts \\ []) do
    Signal.deserialize(binary, opts)
  end
end
