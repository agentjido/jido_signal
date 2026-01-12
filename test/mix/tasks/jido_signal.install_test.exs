defmodule Mix.Tasks.JidoSignal.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "installer posts correct notice" do
    test_project()
    |> Igniter.compose_task("jido_signal.install", [])
    |> assert_has_notice("""
    Jido Signal installed successfully !

    To get started, follow the guide at:
    https://hexdocs.pm/jido_signal/getting-started.html
    """)
  end
end
