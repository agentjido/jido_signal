defmodule Jido.Signal.Router.CountTest do
  use ExUnit.Case, async: true

  alias Jido.Signal.Router

  test "count/1 counts Route values, not targets" do
    router =
      Router.new!([
        {"user.created", :user},
        {"system.error", [:logger, :metrics, :alert]}
      ])

    assert Router.count(router) == 2
  end

  test "count/1 follows add and remove operations" do
    router = Router.new!({"user.created", :created})
    assert Router.count(router) == 1

    assert {:ok, router} =
             Router.add(router, [
               {"user.updated", :updated},
               {"order.**", :order}
             ])

    assert Router.count(router) == 3

    assert {:ok, router} = Router.remove(router, ["user.created", "order.**"])
    assert Router.count(router) == 1

    assert {:ok, router} = Router.remove(router, "user.updated")
    assert Router.count(router) == 0
    assert Router.empty?(router)
  end

  test "removing a missing path does not change the count" do
    router = Router.new!({"user.created", :created})
    assert {:ok, router} = Router.remove(router, "missing")
    assert Router.count(router) == 1
  end
end
