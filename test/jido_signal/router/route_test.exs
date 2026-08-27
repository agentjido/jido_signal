defmodule Jido.Signal.Router.RouteTest do
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
      refute_received :match_called
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

    test "validates each Route field boundary" do
      assert {:error, "Path must be a string"} = Route.validate_path(:invalid, [])
      assert :ok = Route.validate_priority(nil, [])
      assert :ok = Route.validate_priority(0, [])

      assert {:error, "Priority value below minimum allowed"} =
               Route.validate_priority(-101, [])

      assert {:error, "Priority must be an integer"} = Route.validate_priority("high", [])
      assert :ok = Route.validate_match(nil, [])
      assert :ok = Route.validate_match(fn _signal -> true end, [])
    end
  end
end
