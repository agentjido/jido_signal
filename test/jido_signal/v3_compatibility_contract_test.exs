defmodule Jido.Signal.V3CompatibilityContractTest do
  use ExUnit.Case, async: false

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias Jido.Signal.Dispatch
  alias Jido.Signal.Error
  alias Jido.Signal.Router
  @fixtures Path.expand("../fixtures/v2", __DIR__)

  describe "Signal constructor contract" do
    test "generates only the Jido-owned envelope values" do
      assert {:ok, signal} =
               Signal.new(%{type: "compat.created", source: "/compat", data: %{id: 1}})

      assert signal.type == "compat.created"
      assert signal.data == %{id: 1}
      assert signal.specversion == "1.0"
      assert signal.datacontenttype == nil
      assert is_binary(signal.id)
      assert signal.source == "/compat"
      assert signal.time == nil
    end
  end

  describe "v2 serialized fixtures" do
    for {filename, format, encoded?} <- [
          {"signal.json", :json, false},
          {"signal.erlang.b64", :erlang_term, true}
        ] do
      @filename filename
      @format format
      @encoded? encoded?

      test "decodes #{@filename}" do
        binary = File.read!(Path.join(@fixtures, @filename))
        binary = if @encoded?, do: Base.decode64!(String.trim(binary)), else: binary

        assert {:ok, signal} = Signal.deserialize(binary, format: @format)
        assert_fixture_signal(signal)
      end
    end

    test "rejects the deprecated dispatch field as Signal metadata" do
      map = %{
        "specversion" => "1.0.2",
        "id" => "legacy-dispatch",
        "source" => "/compat",
        "type" => "compat.dispatch",
        "jido_dispatch" => {:noop, []}
      }

      assert {:error, error} = Signal.from_map(map)
      assert error =~ "jido_dispatch"
    end
  end

  describe "Router precedence" do
    test "orders exact, single wildcard, and multi wildcard before priority" do
      router =
        Router.new!([
          {"user.**", :multi, 100},
          {"user.*", :single, 100},
          {"user.created", :exact, -100}
        ])

      signal = Signal.new!("user.created", %{}, source: "/compat")

      assert {:ok, [:exact, :single, :multi]} = Router.route(router, signal)
    end

    test "uses priority before registration order for equal patterns" do
      router =
        Router.new!([
          {"user.created", :first, 0},
          {"user.created", :high, 10},
          {"user.created", :last, 0}
        ])

      signal = Signal.new!("user.created", %{}, source: "/compat")

      assert {:ok, [:high, :first, :last]} = Router.route(router, signal)
    end

    test "keeps the structured no-match error" do
      signal = Signal.new!("unmatched.created", %{}, source: "/compat")

      assert {:error, %Error.RoutingError{}} = Router.route(Router.new!(), signal)
    end
  end

  describe "Dispatch tuple and result contracts" do
    test "accepts nil, built-in, custom, and multi-target tuple forms" do
      assert {:ok, {nil, []}} = Dispatch.validate_opts({nil, []})
      assert {:ok, {:pid, opts}} = Dispatch.validate_opts({:pid, target: self()})
      assert opts[:target] == self()

      assert {:ok, [{:noop, []}, {:pid, pid_opts}]} =
               Dispatch.validate_opts([{:noop, []}, {:pid, target: self()}])

      assert pid_opts[:target] == self()
    end

    test "keeps single and multi-target result shapes" do
      signal = Signal.new!("compat.dispatch", %{}, source: "/compat")

      assert :ok = Dispatch.dispatch(signal, {:noop, []})
      assert :ok = Dispatch.dispatch(signal, [{:noop, []}, {:noop, []}])
      assert {:error, :invalid_dispatch_config} = Dispatch.validate_opts(:invalid)
    end
  end

  describe "Bus basic pub/sub contract" do
    test "starts, subscribes, publishes, delivers, and unsubscribes" do
      name = String.to_atom("compat_bus_#{System.unique_integer([:positive])}")
      start_supervised!({Bus, name: name})

      assert {:ok, subscription_id} = Bus.subscribe(name, "compat.*")

      signal = Signal.new!("compat.created", %{id: 1}, source: "/compat")
      assert {:ok, [recorded]} = Bus.publish(name, [signal])
      assert recorded.signal == signal
      assert_receive {:signal, ^signal}

      assert :ok = Bus.unsubscribe(name, subscription_id)
      assert {:ok, [_recorded]} = Bus.publish(name, [signal])
      refute_receive {:signal, ^signal}, 50
    end
  end

  defp assert_fixture_signal(signal) do
    assert signal.id == "v2-fixture-1"
    assert signal.source == "/v2-fixture"
    assert signal.type == "fixture.created"
    assert signal.subject == "subject-1"
    assert signal.time == "2025-01-02T03:04:05Z"
    assert signal.data == %{"count" => 1, "ok" => true}

    refute Map.has_key?(signal.extensions, "jido_schema_version")
  end
end
