defmodule Jido.Signal.Config do
  @moduledoc """
  Centralized application configuration access for `jido_signal`.

  `:jido_signal` is the preferred app namespace. Reads fall back to legacy `:jido`
  keys for backwards compatibility.
  """

  @preferred_app :jido_signal
  @legacy_app :jido

  @spec get_env(atom(), term()) :: term()
  def get_env(key, default \\ nil) when is_atom(key) do
    case Application.fetch_env(@preferred_app, key) do
      {:ok, value} -> value
      :error -> Application.get_env(@legacy_app, key, default)
    end
  end

  @spec put_env(atom(), term()) :: :ok
  def put_env(key, value) when is_atom(key) do
    Application.put_env(@preferred_app, key, value)
  end
end
