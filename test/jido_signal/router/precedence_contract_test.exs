defmodule Jido.Signal.Router.PrecedenceContractTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Error
  alias Jido.Signal.Router

  defp signal(type, data \\ %{}) do
    %Signal{id: "router-contract", source: "/test", type: type, data: data}
  end

  test "exact routes run before single and multi wildcard routes" do
    router =
      Router.new!([
        {"user.123.created", :exact, -100},
        {"user.*.created", :single, 100},
        {"user.**", :multi, 100}
      ])

    assert {:ok, [:exact, :single, :multi]} =
             Router.route(router, signal("user.123.created"))
  end

  test "pattern complexity runs before priority within a wildcard class" do
    router =
      Router.new!([
        {"user.*.created", :more_specific, -100},
        {"*.123.created", :less_specific, 100}
      ])

    assert {:ok, [:more_specific, :less_specific]} =
             Router.route(router, signal("user.123.created"))
  end

  test "priority runs before registration order for equal patterns" do
    router =
      Router.new!([
        {"user.created", :registered_first, 0},
        {"user.created", :higher_priority, 50}
      ])

    assert {:ok, [:higher_priority, :registered_first]} =
             Router.route(router, signal("user.created"))
  end

  test "registration order breaks the final tie" do
    router =
      Router.new!([
        {"user.created", :first},
        {"user.created", :second}
      ])

    assert {:ok, [:first, :second]} = Router.route(router, signal("user.created"))
  end

  test "Route.match filters a path match" do
    router =
      Router.new!({
        "payment.processed",
        fn signal -> signal.data.amount > 100 end,
        :large_payment
      })

    assert {:ok, [:large_payment]} =
             Router.route(router, signal("payment.processed", %{amount: 101}))

    assert {:error, %Error.RoutingError{}} =
             Router.route(router, signal("payment.processed", %{amount: 100}))
  end
end
