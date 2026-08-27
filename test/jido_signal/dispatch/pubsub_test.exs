defmodule Jido.Signal.Dispatch.PubSubTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Dispatch

  test "parses the PubSub target with Zoi" do
    assert {:ok, {:pubsub, opts}} =
             Dispatch.validate_opts({:pubsub, target: __MODULE__, topic: "events.created"})

    assert opts == [target: __MODULE__, topic: "events.created"]

    for invalid <- [
          {:pubsub, topic: "events.created"},
          {:pubsub, target: nil, topic: "events.created"},
          {:pubsub, target: __MODULE__},
          {:pubsub, target: __MODULE__, topic: :events},
          {:pubsub, target: __MODULE__, topic: "events", unknown: true}
        ] do
      assert {:error, _reason} = Dispatch.validate_opts(invalid)
    end
  end

  test "broadcasts a Signal on the selected topic" do
    name = Module.concat(__MODULE__, "Server#{System.unique_integer([:positive])}")
    start_supervised!({Phoenix.PubSub, name: name})
    :ok = Phoenix.PubSub.subscribe(name, "orders")
    signal = Signal.new!("order.created", %{id: "ord-1"}, source: "/test")

    assert :ok = Dispatch.dispatch(signal, {:pubsub, target: name, topic: "orders"})
    assert_receive ^signal
  end

  test "keeps topics isolated" do
    name = Module.concat(__MODULE__, "Isolated#{System.unique_integer([:positive])}")
    start_supervised!({Phoenix.PubSub, name: name})
    :ok = Phoenix.PubSub.subscribe(name, "wanted")
    signal = Signal.new!("order.created", %{}, source: "/test")

    assert :ok = Dispatch.dispatch(signal, {:pubsub, target: name, topic: "other"})
    refute_receive ^signal
  end

  test "returns a stable error when the PubSub server is not running" do
    signal = Signal.new!("order.created", %{}, source: "/test")

    assert {:error, :pubsub_not_found} =
             Dispatch.dispatch(
               signal,
               {:pubsub, target: __MODULE__.Missing, topic: "orders"}
             )
  end
end
