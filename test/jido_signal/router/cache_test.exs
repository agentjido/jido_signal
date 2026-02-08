defmodule Jido.Signal.Router.CacheTest do
  use ExUnit.Case, async: false

  alias Jido.Signal
  alias Jido.Signal.Error
  alias Jido.Signal.ID
  alias Jido.Signal.Router
  alias Jido.Signal.Router.Cache

  @moduletag :capture_log

  setup do
    # Clean up any cached routers from previous tests
    for cache_id <- Cache.list_cached() do
      Cache.delete(cache_id)
    end

    :ok
  end

  describe "Cache.put/2 and Cache.get/1" do
    test "caches and retrieves a router" do
      {:ok, router} = Router.new([{"user.created", :handler1}])

      assert :ok = Cache.put(:test_router, router)
      assert {:ok, cached} = Cache.get(:test_router)
      assert cached.route_count == 1
    end

    test "returns normalized error for uncached router" do
      assert {:error, %Error.RoutingError{} = error} = Cache.get(:nonexistent)
      assert error.details[:reason] == :not_found
    end

    test "supports tuple cache_ids for namespacing" do
      {:ok, router} = Router.new([{"user.created", :handler1}])

      assert :ok = Cache.put({:myapp, :user_router}, router)
      assert {:ok, cached} = Cache.get({:myapp, :user_router})
      assert cached.route_count == 1

      # Clean up
      Cache.delete({:myapp, :user_router})
    end
  end

  describe "Cache.delete/1" do
    test "removes a cached router" do
      {:ok, router} = Router.new([{"user.created", :handler1}])
      Cache.put(:delete_test, router)

      assert Cache.cached?(:delete_test)
      assert :ok = Cache.delete(:delete_test)
      refute Cache.cached?(:delete_test)
    end

    test "succeeds even if cache_id doesn't exist" do
      assert :ok = Cache.delete(:never_existed)
    end
  end

  describe "Cache.cached?/1" do
    test "returns true for cached routers" do
      {:ok, router} = Router.new([{"user.created", :handler1}])
      Cache.put(:cached_check, router)

      assert Cache.cached?(:cached_check)
    end

    test "returns false for uncached routers" do
      refute Cache.cached?(:not_cached)
    end
  end

  describe "Cache.route/2" do
    test "routes signals using cached trie" do
      {:ok, router} = Router.new([{"user.created", :handler1}])
      Cache.put(:route_test, router)

      signal = %Signal{
        id: ID.generate!(),
        source: "/test",
        type: "user.created",
        data: %{}
      }

      assert {:ok, [:handler1]} = Cache.route(:route_test, signal)
    end

    test "returns normalized cache-miss error for uncached router" do
      signal = %Signal{
        id: ID.generate!(),
        source: "/test",
        type: "user.created",
        data: %{}
      }

      assert {:error, %Error.RoutingError{} = error} = Cache.route(:not_there, signal)
      assert error.details[:reason] == :not_found
    end

    test "returns error for nil signal type" do
      {:ok, router} = Router.new([{"user.created", :handler1}])
      Cache.put(:nil_type_test, router)

      signal = %Signal{
        id: ID.generate!(),
        source: "/test",
        type: nil,
        data: %{}
      }

      assert {:error, _error} = Cache.route(:nil_type_test, signal)
    end

    test "returns error when no handlers match" do
      {:ok, router} = Router.new([{"user.created", :handler1}])
      Cache.put(:no_match_test, router)

      signal = %Signal{
        id: ID.generate!(),
        source: "/test",
        type: "payment.processed",
        data: %{}
      }

      assert {:error, _error} = Cache.route(:no_match_test, signal)
    end

    test "supports wildcard patterns" do
      {:ok, router} =
        Router.new([
          {"user.*", :single_wildcard},
          {"audit.**", :multi_wildcard}
        ])

      Cache.put(:wildcard_test, router)

      signal1 = %Signal{
        id: ID.generate!(),
        source: "/test",
        type: "user.created",
        data: %{}
      }

      signal2 = %Signal{
        id: ID.generate!(),
        source: "/test",
        type: "audit.user.login.success",
        data: %{}
      }

      assert {:ok, [:single_wildcard]} = Cache.route(:wildcard_test, signal1)
      assert {:ok, [:multi_wildcard]} = Cache.route(:wildcard_test, signal2)
    end
  end

  describe "Cache.list_cached/0" do
    test "lists all cached router IDs" do
      {:ok, router1} = Router.new([{"user.created", :handler1}])
      {:ok, router2} = Router.new([{"payment.processed", :handler2}])

      Cache.put(:list_test_1, router1)
      Cache.put(:list_test_2, router2)

      cached = Cache.list_cached()
      assert :list_test_1 in cached
      assert :list_test_2 in cached
    end

    test "returns empty list when no routers cached" do
      # Clean up first
      for cache_id <- Cache.list_cached() do
        Cache.delete(cache_id)
      end

      assert Cache.list_cached() == []
    end
  end

  describe "Cache.update/2" do
    test "updates cached router with new routes" do
      {:ok, router} = Router.new([{"user.created", :handler1}])
      Cache.put(:update_test, router)

      assert {:ok, updated} = Cache.update(:update_test, {"user.updated", :handler2})
      assert updated.route_count == 2

      # Verify both routes work
      signal1 = %Signal{
        id: ID.generate!(),
        source: "/test",
        type: "user.created",
        data: %{}
      }

      signal2 = %Signal{
        id: ID.generate!(),
        source: "/test",
        type: "user.updated",
        data: %{}
      }

      assert {:ok, [:handler1]} = Cache.route(:update_test, signal1)
      assert {:ok, [:handler2]} = Cache.route(:update_test, signal2)
    end

    test "creates new cached router if not exists" do
      refute Cache.cached?(:new_via_update)

      assert {:ok, router} = Cache.update(:new_via_update, {"user.created", :handler1})
      assert router.route_count == 1
      assert Cache.cached?(:new_via_update)
    end
  end

  describe "Router.new/2 with cache_id option" do
    test "automatically caches router when cache_id provided" do
      refute Cache.cached?(:auto_cache)

      {:ok, router} = Router.new([{"user.created", :handler1}], cache_id: :auto_cache)

      assert router.cache_id == :auto_cache
      assert Cache.cached?(:auto_cache)

      # Verify routing works
      signal = %Signal{
        id: ID.generate!(),
        source: "/test",
        type: "user.created",
        data: %{}
      }

      assert {:ok, [:handler1]} = Cache.route(:auto_cache, signal)
    end

    test "does not cache when cache_id not provided" do
      initial_count = length(Cache.list_cached())
      {:ok, _router} = Router.new([{"user.created", :handler1}])

      assert length(Cache.list_cached()) == initial_count
    end

    test "new! also caches when cache_id provided" do
      refute Cache.cached?(:new_bang_cache)

      router = Router.new!([{"user.created", :handler1}], cache_id: :new_bang_cache)

      assert router.cache_id == :new_bang_cache
      assert Cache.cached?(:new_bang_cache)
    end
  end

  describe "Router.add/2 with cached router" do
    test "updates cache when routes are added" do
      {:ok, router} = Router.new([{"user.created", :handler1}], cache_id: :add_cache_test)

      {:ok, updated} = Router.add(router, {"user.updated", :handler2})

      # Verify cache was updated
      signal = %Signal{
        id: ID.generate!(),
        source: "/test",
        type: "user.updated",
        data: %{}
      }

      assert {:ok, [:handler2]} = Cache.route(:add_cache_test, signal)
      assert updated.cache_id == :add_cache_test
    end
  end

  describe "Router.remove/2 with cached router" do
    test "updates cache when routes are removed" do
      {:ok, router} =
        Router.new(
          [{"user.created", :handler1}, {"user.updated", :handler2}],
          cache_id: :remove_cache_test
        )

      {:ok, updated} = Router.remove(router, "user.created")

      # Verify removed route no longer matches
      signal = %Signal{
        id: ID.generate!(),
        source: "/test",
        type: "user.created",
        data: %{}
      }

      assert {:error, _error} = Cache.route(:remove_cache_test, signal)
      assert updated.cache_id == :remove_cache_test
      assert updated.route_count == 1
    end
  end

  describe "multiple routers coexistence" do
    test "multiple routers can be cached simultaneously" do
      {:ok, router1} = Router.new([{"user.created", :user_handler}], cache_id: :router_1)
      {:ok, router2} = Router.new([{"payment.processed", :payment_handler}], cache_id: :router_2)
      {:ok, router3} = Router.new([{"audit.**", :audit_handler}], cache_id: {:app, :audit})

      user_signal = %Signal{
        id: ID.generate!(),
        source: "/test",
        type: "user.created",
        data: %{}
      }

      payment_signal = %Signal{
        id: ID.generate!(),
        source: "/test",
        type: "payment.processed",
        data: %{}
      }

      audit_signal = %Signal{
        id: ID.generate!(),
        source: "/test",
        type: "audit.user.login",
        data: %{}
      }

      assert {:ok, [:user_handler]} = Cache.route(:router_1, user_signal)
      assert {:ok, [:payment_handler]} = Cache.route(:router_2, payment_signal)
      assert {:ok, [:audit_handler]} = Cache.route({:app, :audit}, audit_signal)

      # Verify they don't interfere
      assert {:error, _} = Cache.route(:router_1, payment_signal)
      assert {:error, _} = Cache.route(:router_2, user_signal)

      # Verify all exist
      assert router1.cache_id == :router_1
      assert router2.cache_id == :router_2
      assert router3.cache_id == {:app, :audit}
    end
  end

  describe "telemetry" do
    test "emits [:jido, :signal, :router, :routed] event on successful route" do
      {:ok, _router} = Router.new([{"user.created", :handler1}], cache_id: :telemetry_test)

      test_pid = self()

      :telemetry.attach(
        "test-router-telemetry",
        [:jido, :signal, :router, :routed],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      signal = %Signal{
        id: ID.generate!(),
        source: "/test",
        type: "user.created",
        data: %{}
      }

      {:ok, [:handler1]} = Cache.route(:telemetry_test, signal)

      assert_receive {:telemetry_event, [:jido, :signal, :router, :routed], measurements,
                      metadata}

      assert is_integer(measurements.latency_us)
      assert measurements.match_count == 1
      assert metadata.signal_type == "user.created"
      assert metadata.cache_id == :telemetry_test
      assert metadata.matched == true

      :telemetry.detach("test-router-telemetry")
    end

    test "emits telemetry event with matched: false when no handlers found" do
      {:ok, _router} = Router.new([{"user.created", :handler1}], cache_id: :telemetry_nomatch)

      test_pid = self()

      :telemetry.attach(
        "test-router-telemetry-nomatch",
        [:jido, :signal, :router, :routed],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      signal = %Signal{
        id: ID.generate!(),
        source: "/test",
        type: "payment.processed",
        data: %{}
      }

      {:error, _} = Cache.route(:telemetry_nomatch, signal)

      assert_receive {:telemetry_event, [:jido, :signal, :router, :routed], measurements,
                      metadata}

      assert measurements.match_count == 0
      assert metadata.matched == false

      :telemetry.detach("test-router-telemetry-nomatch")
    end
  end
end
