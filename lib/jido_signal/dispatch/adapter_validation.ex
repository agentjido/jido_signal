defmodule Jido.Signal.Dispatch.AdapterValidation do
  @moduledoc false

  @spec validate_target_and_mode(Keyword.t(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, Keyword.t()} | {:error, term()}
  def validate_target_and_mode(opts, target_validator) when is_list(opts) do
    with {:ok, target} <- target_validator.(Keyword.get(opts, :target)),
         {:ok, mode} <- validate_mode(Keyword.get(opts, :delivery_mode, :async)) do
      {:ok,
       opts
       |> Keyword.put(:target, target)
       |> Keyword.put(:delivery_mode, mode)}
    end
  end

  @spec validate_mode(term()) :: {:ok, :sync | :async} | {:error, :invalid_delivery_mode}
  def validate_mode(mode) when mode in [:sync, :async], do: {:ok, mode}
  def validate_mode(_), do: {:error, :invalid_delivery_mode}
end
