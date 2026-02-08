defmodule Jido.Signal.Context do
  @moduledoc """
  Shared context helpers for instance-scoped (`jido:`) options.
  """

  @doc """
  Extracts normalized `jido:` options from maps or keyword lists.
  """
  @spec jido_opts(map() | keyword() | term()) :: keyword()
  def jido_opts(%{jido: instance}) when is_atom(instance), do: [jido: instance]
  def jido_opts(%{jido: _}), do: []

  def jido_opts(opts) when is_list(opts) do
    case Keyword.get(opts, :jido) do
      instance when is_atom(instance) -> [jido: instance]
      _ -> []
    end
  end

  def jido_opts(_), do: []
end
