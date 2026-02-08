defmodule Jido.Signal.Bus.SignalValidation do
  @moduledoc false

  alias Jido.Signal

  @spec validate_signals([term()]) :: :ok | {:error, :invalid_signals}
  def validate_signals(signals) when is_list(signals) do
    if Enum.all?(signals, &is_struct(&1, Signal)) do
      :ok
    else
      {:error, :invalid_signals}
    end
  end

  def validate_signals(_), do: {:error, :invalid_signals}
end
