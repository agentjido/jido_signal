defmodule Jido.Signal.Router.WildcardDeepTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.ID
  alias Jido.Signal.Router

  describe "deep multi-wildcard paths" do
    test "handles 50-segment path without stack overflow" do
      {:ok, router} = Router.new({"a.**.z", :handler})

      # Build path: a.1.2.3...48.z
      middle = Enum.join(1..48, ".")

      signal = %Signal{
        type: "a.#{middle}.z",
        source: "/test",
        id: ID.generate!(),
        specversion: "1.0.2",
        data: %{}
      }

      assert {:ok, [:handler]} = Router.route(router, signal)
    end

    test "multiple ** in pattern works correctly" do
      {:ok, router} = Router.new({"a.**.m.**.z", :handler})

      signal = %Signal{
        type: "a.b.c.m.x.y.z",
        source: "/test",
        id: ID.generate!(),
        specversion: "1.0.2",
        data: %{}
      }

      assert {:ok, [:handler]} = Router.route(router, signal)
    end

    test "maintains handler ordering with ** patterns" do
      {:ok, router} =
        Router.new([
          {"user.**.created", :handler_wildcard, 0},
          {"user.123.created", :handler_exact, 100}
        ])

      signal = %Signal{
        type: "user.123.created",
        source: "/test",
        id: ID.generate!(),
        specversion: "1.0.2",
        data: %{}
      }

      {:ok, handlers} = Router.route(router, signal)

      # Exact match (higher complexity) should come first
      assert handlers == [:handler_exact, :handler_wildcard]
    end

    test "handles single segment matching with **" do
      {:ok, router} = Router.new({"a.**.b", :handler})

      # ** matches one segment
      signal = %Signal{
        type: "a.x.b",
        source: "/test",
        id: ID.generate!(),
        specversion: "1.0.2",
        data: %{}
      }

      assert {:ok, [:handler]} = Router.route(router, signal)
    end

    test "handles multiple segments with **" do
      {:ok, router} = Router.new({"order.**", :handler})

      signal = %Signal{
        type: "order.123.payment.completed",
        source: "/test",
        id: ID.generate!(),
        specversion: "1.0.2",
        data: %{}
      }

      assert {:ok, [:handler]} = Router.route(router, signal)
    end

    test "handles nested ** patterns with different priorities" do
      {:ok, router} =
        Router.new([
          {"**.created", :handler_general, 0},
          {"user.**.created", :handler_user, 50},
          {"user.123.created", :handler_specific, 100}
        ])

      signal = %Signal{
        type: "user.123.created",
        source: "/test",
        id: ID.generate!(),
        specversion: "1.0.2",
        data: %{}
      }

      {:ok, handlers} = Router.route(router, signal)

      # Higher complexity and priority should come first
      assert handlers == [:handler_specific, :handler_user, :handler_general]
    end

    test "handles very deep path without performance issues" do
      {:ok, router} = Router.new({"start.**.end", :handler})

      # Build a 100-segment path
      middle = Enum.join(1..98, ".")

      signal = %Signal{
        type: "start.#{middle}.end",
        source: "/test",
        id: ID.generate!(),
        specversion: "1.0.2",
        data: %{}
      }

      assert {:ok, [:handler]} = Router.route(router, signal)
    end

    test "handles ** at the beginning of pattern" do
      {:ok, router} = Router.new({"**.completed", :handler})

      signal = %Signal{
        type: "order.payment.completed",
        source: "/test",
        id: ID.generate!(),
        specversion: "1.0.2",
        data: %{}
      }

      assert {:ok, [:handler]} = Router.route(router, signal)
    end

    test "handles ** at the end of pattern" do
      {:ok, router} = Router.new({"order.**", :handler})

      signal = %Signal{
        type: "order.payment.completed",
        source: "/test",
        id: ID.generate!(),
        specversion: "1.0.2",
        data: %{}
      }

      assert {:ok, [:handler]} = Router.route(router, signal)
    end

    test "handles multiple ** patterns matching same signal" do
      {:ok, router} =
        Router.new([
          {"a.**.z", :handler1, 0},
          {"**.m.**.z", :handler2, 50}
        ])

      signal = %Signal{
        type: "a.b.c.m.x.y.z",
        source: "/test",
        id: ID.generate!(),
        specversion: "1.0.2",
        data: %{}
      }

      {:ok, handlers} = Router.route(router, signal)

      # Both should match, ordered by priority
      assert :handler2 in handlers
      assert :handler1 in handlers
    end
  end
end
