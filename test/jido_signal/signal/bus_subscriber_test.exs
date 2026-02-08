defmodule JidoTest.Signal.Bus.SubscriberTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus.State, as: BusState
  alias Jido.Signal.Bus.Subscriber
  alias Jido.Signal.Journal.Adapters.InMemory

  describe "subscribe/4" do
    setup do
      # Create a basic bus state for testing
      {:ok, supervisor_pid} = DynamicSupervisor.start_link(strategy: :one_for_one)

      state = BusState.new(:test_bus, child_supervisor: supervisor_pid)

      {:ok, state: state}
    end

    test "creates a non-persistent subscription", %{state: state} do
      subscription_id = "test-sub-1"
      path = "test.*"
      dispatch = {:pid, target: self()}

      result = Subscriber.subscribe(state, subscription_id, path, dispatch: dispatch)

      assert {:ok, new_state} = result
      assert BusState.has_subscription?(new_state, subscription_id)

      subscription = BusState.get_subscription(new_state, subscription_id)
      assert subscription.id == subscription_id
      assert subscription.path == path
      assert subscription.dispatch == dispatch
      assert subscription.persistent? == false
      assert subscription.persistence_pid == nil
    end

    test "creates a persistent subscription", %{state: state} do
      subscription_id = "test-sub-1"
      path = "test.*"
      client_dispatch = {:pid, target: self()}

      result =
        Subscriber.subscribe(state, subscription_id, path,
          dispatch: client_dispatch,
          persistent?: true
        )

      assert {:ok, new_state} = result
      assert BusState.has_subscription?(new_state, subscription_id)

      subscription = BusState.get_subscription(new_state, subscription_id)
      assert subscription.id == subscription_id
      assert subscription.path == path
      assert subscription.persistent? == true
      assert subscription.persistence_pid != nil
      assert Process.alive?(subscription.persistence_pid)

      # For persistent subscriptions, the dispatch target should be the persistence process
      # This is how signals get routed to the persistent subscription process first
      assert {:pid, target: _target} = subscription.dispatch

      # The persistent subscription process should be alive
      assert Process.alive?(subscription.persistence_pid)

      # Get persistent subscription state and verify it has the original client dispatch config
      persistent_sub_state = :sys.get_state(subscription.persistence_pid)
      assert persistent_sub_state.bus_subscription.dispatch == client_dispatch

      # Verify the client_pid in the persistent subscription is set to our test process
      assert persistent_sub_state.client_pid == self()
    end

    test "supports persistent option alias without question mark", %{state: state} do
      subscription_id = "test-sub-alias"
      path = "test.*"
      client_dispatch = {:pid, target: self()}

      assert {:ok, new_state} =
               Subscriber.subscribe(state, subscription_id, path,
                 dispatch: client_dispatch,
                 persistent: true
               )

      subscription = BusState.get_subscription(new_state, subscription_id)
      assert subscription.persistent? == true
      assert is_pid(subscription.persistence_pid)
    end

    test "returns error when subscription already exists", %{state: state} do
      subscription_id = "test-sub-1"
      path = "test.*"
      dispatch = {:pid, target: self()}

      # Add the subscription first
      {:ok, state} = Subscriber.subscribe(state, subscription_id, path, dispatch: dispatch)

      # Try to add it again
      result = Subscriber.subscribe(state, subscription_id, path, dispatch: dispatch)

      assert {:error, error} = result
      # error type assertion removed since new error structure doesn't have class field
      assert error.message =~ "Subscription already exists"
    end
  end

  describe "unsubscribe/3" do
    setup do
      # Create a basic bus state for testing
      {:ok, supervisor_pid} = DynamicSupervisor.start_link(strategy: :one_for_one)

      state = BusState.new(:test_bus, child_supervisor: supervisor_pid)

      # Add a regular subscription
      subscription_id = "test-sub-1"
      path = "test.*"
      dispatch = {:pid, target: self()}

      {:ok, state} = Subscriber.subscribe(state, subscription_id, path, dispatch: dispatch)

      {:ok, state: state, subscription_id: subscription_id}
    end

    test "removes a subscription", %{state: state, subscription_id: subscription_id} do
      result = Subscriber.unsubscribe(state, subscription_id)

      assert {:ok, new_state} = result
      refute BusState.has_subscription?(new_state, subscription_id)
    end

    test "returns error when subscription does not exist", %{state: state} do
      result = Subscriber.unsubscribe(state, "non-existent-sub")

      assert {:error, error} = result
      # error type assertion removed since new error structure doesn't have class field
      assert error.message =~ "Subscription does not exist"
    end

    test "delete_persistence clears stored checkpoint and dlq data" do
      {:ok, supervisor_pid} = DynamicSupervisor.start_link(strategy: :one_for_one)
      {:ok, journal_pid} = InMemory.init()
      on_exit(fn -> if Process.alive?(journal_pid), do: Agent.stop(journal_pid) end)

      state =
        BusState.new(:test_bus,
          child_supervisor: supervisor_pid,
          journal_adapter: InMemory,
          journal_pid: journal_pid
        )

      subscription_id = "persistent-sub"
      dispatch = {:pid, target: self()}

      assert {:ok, state} =
               Subscriber.subscribe(state, subscription_id, "test.*",
                 dispatch: dispatch,
                 persistent?: true
               )

      checkpoint_key = "#{state.name}:#{subscription_id}"
      assert :ok = InMemory.put_checkpoint(checkpoint_key, 123, journal_pid)

      {:ok, signal} = Signal.new(%{type: "test.event", source: "/test", data: %{value: 1}})

      assert {:ok, _entry_id} =
               InMemory.put_dlq_entry(subscription_id, signal, :failed, %{}, journal_pid)

      assert {:ok, _new_state} =
               Subscriber.unsubscribe(state, subscription_id, delete_persistence: true)

      assert {:error, :not_found} = InMemory.get_checkpoint(checkpoint_key, journal_pid)
      assert {:ok, []} = InMemory.get_dlq_entries(subscription_id, journal_pid)
    end
  end

  describe "schema validation" do
    test "accepts tuple dispatch config and list of dispatch configs" do
      created_at = DateTime.utc_now()

      base = %Subscriber{
        id: "schema-sub-1",
        path: "schema.*",
        dispatch: {:pid, [target: self(), delivery_mode: :async]},
        persistent?: false,
        persistence_pid: nil,
        disconnected?: false,
        created_at: created_at
      }

      assert {:ok, parsed_tuple} =
               Zoi.parse(Subscriber.schema(), base)

      assert parsed_tuple.dispatch == {:pid, [target: self(), delivery_mode: :async]}

      assert {:ok, parsed_list} =
               Zoi.parse(Subscriber.schema(), %{
                 base
                 | id: "schema-sub-2",
                   dispatch: [{:noop, []}, {:pid, [target: self(), delivery_mode: :async]}]
               })

      assert is_list(parsed_list.dispatch)
    end

    test "rejects non-dispatch values for dispatch field" do
      assert {:error, _errors} =
               Zoi.parse(
                 Subscriber.schema(),
                 %Subscriber{
                   id: "schema-sub-3",
                   path: "schema.*",
                   dispatch: "invalid-dispatch-shape",
                   persistent?: false,
                   persistence_pid: nil,
                   disconnected?: false,
                   created_at: DateTime.utc_now()
                 }
               )
    end
  end
end
