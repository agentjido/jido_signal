defmodule Jido.Signal.RouterDefinitionTest do
  use ExUnit.Case, async: true

  alias Jido.Signal.Router
  alias Jido.Signal.Router.Route

  describe "normalize/1" do
    test "accepts Route values and all tuple forms" do
      match = fn _signal -> true end
      route = %Route{path: "route.value", target: :route}

      assert {:ok, [^route]} = Router.normalize(route)

      assert {:ok, [%Route{path: "simple", target: :simple}]} =
               Router.normalize({"simple", :simple})

      assert {:ok, [%Route{path: "priority", target: :priority, priority: 10}]} =
               Router.normalize({"priority", :priority, 10})

      assert {:ok, [%Route{path: "matched", match: ^match, target: :matched}]} =
               Router.normalize({"matched", match, :matched})

      assert {:ok,
              [%Route{path: "matched.priority", match: ^match, target: :matched, priority: 20}]} =
               Router.normalize({"matched.priority", match, :matched, 20})
    end

    test "accepts any target term" do
      targets = [noop: [key: "value"], pid: [target: self()]]

      assert {:ok, [%Route{target: ^targets}]} =
               Router.normalize({"target.list", targets})

      assert {:ok, [%Route{target: {:custom, %{value: 1}}}]} =
               Router.normalize({"target.custom", {:custom, %{value: 1}}})
    end

    test "validates paths while it normalizes" do
      assert {:error, error} = Router.normalize({"invalid..path", :target})
      assert error.message == "Path cannot contain consecutive dots"
    end

    test "returns a structured error for an invalid specification" do
      assert {:error, error} = Router.normalize({:invalid, "format"})
      assert error.message == "Invalid route specification format"
    end
  end

  describe "validate/1" do
    test "uses the Route Zoi schema" do
      route = %Route{path: "test.path", target: :target, priority: 10}

      assert {:ok, ^route} = Zoi.parse(Route.schema(), route)
      assert {:ok, ^route} = Router.validate(route)
      assert {:ok, [^route]} = Router.validate([route])
    end

    test "does not execute Route.match during validation" do
      test_pid = self()

      match = fn _signal ->
        send(test_pid, :match_called)
        true
      end

      route = %Route{path: "test.path", target: :target, match: match}

      assert {:ok, ^route} = Router.validate(route)
      refute_receive :match_called
    end

    test "returns the path validation messages" do
      assert {:error, error} =
               Router.validate(%Route{path: "invalid..path", target: :target})

      assert error.message == "Path cannot contain consecutive dots"

      assert {:error, error} =
               Router.validate(%Route{path: "invalid**path", target: :target})

      assert error.message == "Path cannot contain '**' sequence"

      assert {:error, error} =
               Router.validate(%Route{path: "invalid@path", target: :target})

      assert error.message == "Path contains invalid characters"
    end

    test "returns priority and match validation messages" do
      assert {:error, error} =
               Router.validate(%Route{path: "test", target: :target, priority: 101})

      assert error.message == "Priority value exceeds maximum allowed"

      assert {:error, error} =
               Router.validate(%Route{path: "test", target: :target, match: "invalid"})

      assert error.message == "Match must be a function that takes one argument"
    end

    test "returns a structured error for invalid input" do
      assert {:error, error} = Router.validate(:invalid)
      assert error.message == "Expected Route struct or list of Route structs"
    end
  end

  describe "Router management" do
    test "creates an empty Router" do
      router = Router.new!()

      assert %Router.Router{} = router
      assert Router.empty?(router)
      assert Router.count(router) == 0
      assert {:ok, []} = Router.list(router)
    end

    test "creates and lists Routes in registration order" do
      router =
        Router.new!([
          {"first", :first},
          {"second", :second}
        ])

      assert Router.count(router) == 2
      refute Router.empty?(router)
      assert {:ok, [%Route{path: "first"}, %Route{path: "second"}]} = Router.list(router)
    end

    test "adds Routes in registration order" do
      router = Router.new!({"first", :first})
      assert {:ok, router} = Router.add(router, [{"second", :second}, {"third", :third}])

      assert {:ok, routes} = Router.list(router)
      assert Enum.map(routes, & &1.path) == ["first", "second", "third"]
    end

    test "removes all Routes at the selected paths" do
      router =
        Router.new!([
          {"same", :first},
          {"same", :second},
          {"keep", :keep}
        ])

      assert {:ok, router} = Router.remove(router, "same")
      assert Router.count(router) == 1
      assert {:ok, [%Route{path: "keep"}]} = Router.list(router)

      assert {:ok, unchanged} = Router.remove(router, "missing")
      assert Router.count(unchanged) == 1
    end

    test "updates exact and wildcard indexes during add and remove" do
      router = Router.new!({"user.created", :exact})

      assert {:ok, router} =
               Router.add(router, [
                 {"user.*", :single},
                 {"user.**", :multi}
               ])

      signal = %Jido.Signal{id: "indexes", source: "/test", type: "user.created"}
      assert {:ok, [:exact, :single, :multi]} = Router.route(router, signal)

      assert {:ok, router} = Router.remove(router, "user.*")
      assert {:ok, [:exact, :multi]} = Router.route(router, signal)
      refute Router.has_route?(router, "user.*")

      assert {:ok, router} = Router.remove(router, ["user.created", "user.**"])
      assert Router.empty?(router)
      assert {:error, %Jido.Signal.Error.RoutingError{}} = Router.route(router, signal)
    end

    test "merges Routers by appending their Routes" do
      first = Router.new!([{"one", :one}, {"two", :two}])
      second = Router.new!([{"three", :three}, {"four", :four}])

      assert {:ok, merged} = Router.merge(first, second)
      assert {:ok, routes} = Router.list(merged)
      assert Enum.map(routes, & &1.path) == ["one", "two", "three", "four"]
    end

    test "checks registered route paths exactly" do
      router = Router.new!([{"user.created", :exact}, {"user.*", :wildcard}])

      assert Router.has_route?(router, "user.created")
      assert Router.has_route?(router, "user.*")
      refute Router.has_route?(router, "user.updated")
      refute Router.has_route?(router, "invalid..path")
    end

    test "counts Route values through add and remove operations" do
      router =
        Router.new!([
          {"user.created", :user},
          {"system.error", [:logger, :metrics, :alert]}
        ])

      assert Router.count(router) == 2
      assert {:ok, router} = Router.add(router, {"order.**", :order})
      assert Router.count(router) == 3
      assert {:ok, router} = Router.remove(router, ["user.created", "order.**"])
      assert Router.count(router) == 1
      assert {:ok, router} = Router.remove(router, "missing")
      assert Router.count(router) == 1
    end
  end
end
