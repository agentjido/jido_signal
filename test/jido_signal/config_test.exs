defmodule Jido.Signal.ConfigTest do
  use ExUnit.Case, async: true

  alias Jido.Signal.Config

  setup do
    original_signal = Application.get_env(:jido_signal, :dispatch_max_concurrency)
    original_legacy = Application.get_env(:jido, :dispatch_max_concurrency)

    on_exit(fn ->
      restore_env(:jido_signal, :dispatch_max_concurrency, original_signal)
      restore_env(:jido, :dispatch_max_concurrency, original_legacy)
    end)

    :ok
  end

  test "reads preferred jido_signal config first" do
    Application.put_env(:jido, :dispatch_max_concurrency, 2)
    Application.put_env(:jido_signal, :dispatch_max_concurrency, 9)

    assert 9 == Config.get_env(:dispatch_max_concurrency, 5)
  end

  test "falls back to legacy jido config when preferred key is unset" do
    Application.delete_env(:jido_signal, :dispatch_max_concurrency)
    Application.put_env(:jido, :dispatch_max_concurrency, 7)

    assert 7 == Config.get_env(:dispatch_max_concurrency, 5)
  end

  test "put_env writes preferred jido_signal config only" do
    Application.put_env(:jido, :dispatch_max_concurrency, 3)
    Config.put_env(:dispatch_max_concurrency, 11)

    assert 11 == Application.get_env(:jido_signal, :dispatch_max_concurrency)
    assert 3 == Application.get_env(:jido, :dispatch_max_concurrency)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
