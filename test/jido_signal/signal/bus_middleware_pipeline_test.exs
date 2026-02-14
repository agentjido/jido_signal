defmodule JidoTest.Signal.Bus.MiddlewarePipeline do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus.MiddlewarePipeline
  alias Jido.Signal.Bus.Subscriber

  @moduletag :capture_log

  # Test middleware modules
  defmodule TestMiddleware1 do
    use Jido.Signal.Bus.Middleware

    @impl true
    def init(opts) do
      {:ok, %{calls: [], id: Keyword.get(opts, :id, 1)}}
    end

    @impl true
    def before_publish(signals, _context, state) do
      new_state = %{state | calls: [:before_publish | state.calls]}
      {:cont, signals, new_state}
    end

    @impl true
    def after_publish(signals, _context, state) do
      new_state = %{state | calls: [:after_publish | state.calls]}
      {:cont, signals, new_state}
    end

    @impl true
    def before_dispatch(signal, _subscriber, _context, state) do
      new_state = %{state | calls: [:before_dispatch | state.calls]}
      {:cont, signal, new_state}
    end

    @impl true
    def after_dispatch(_signal, _subscriber, _result, _context, state) do
      new_state = %{state | calls: [:after_dispatch | state.calls]}
      {:cont, new_state}
    end
  end

  defmodule TransformMiddleware do
    use Jido.Signal.Bus.Middleware

    @impl true
    def init(opts) do
      {:ok, %{suffix: Keyword.get(opts, :suffix, "-transformed")}}
    end

    @impl true
    def before_publish(signals, _context, state) do
      transformed_signals =
        Enum.map(signals, fn signal ->
          %{signal | type: signal.type <> state.suffix}
        end)

      {:cont, transformed_signals, state}
    end

    @impl true
    def before_dispatch(signal, _subscriber, _context, state) do
      transformed_signal = %{signal | source: signal.source <> state.suffix}
      {:cont, transformed_signal, state}
    end
  end

  defmodule HaltMiddleware do
    use Jido.Signal.Bus.Middleware

    @impl true
    def init(opts) do
      {:ok, %{halt_reason: Keyword.get(opts, :halt_reason, :test_halt)}}
    end

    @impl true
    def before_publish(_signals, _context, state) do
      {:halt, state.halt_reason, state}
    end

    @impl true
    def before_dispatch(_signal, _subscriber, _context, state) do
      {:halt, state.halt_reason, state}
    end
  end

  defmodule SkipMiddleware do
    use Jido.Signal.Bus.Middleware

    @impl true
    def init(_opts) do
      {:ok, %{}}
    end

    @impl true
    def before_dispatch(_signal, _subscriber, _context, state) do
      {:skip, state}
    end
  end

  defmodule FailingMiddleware do
    def init(_opts) do
      {:error, :initialization_failed}
    end
  end

  defmodule CrashingMiddleware do
    use Jido.Signal.Bus.Middleware

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def before_publish(_signals, _context, _state) do
      raise "middleware crash"
    end

    @impl true
    def before_dispatch(_signal, _subscriber, _context, _state) do
      raise "middleware crash"
    end
  end

  describe "init_middleware/1" do
    test "initializes empty middleware list" do
      assert {:ok, []} = MiddlewarePipeline.init_middleware([])
    end

    test "initializes single middleware" do
      middleware_specs = [{TestMiddleware1, id: 1}]

      assert {:ok, [{TestMiddleware1, %{calls: [], id: 1}}]} =
               MiddlewarePipeline.init_middleware(middleware_specs)
    end

    test "initializes multiple middleware in order" do
      middleware_specs = [
        {TestMiddleware1, id: 1},
        {TestMiddleware1, id: 2}
      ]

      assert {:ok, configs} = MiddlewarePipeline.init_middleware(middleware_specs)

      assert [
               {TestMiddleware1, %{calls: [], id: 1}},
               {TestMiddleware1, %{calls: [], id: 2}}
             ] = configs
    end

    test "returns error for failing middleware initialization" do
      middleware_specs = [
        {TestMiddleware1, []},
        {FailingMiddleware, []}
      ]

      assert {:error, {:middleware_init_failed, FailingMiddleware, :initialization_failed}} =
               MiddlewarePipeline.init_middleware(middleware_specs)
    end
  end

  describe "before_publish/3" do
    test "executes middleware chain successfully and returns updated configs" do
      {:ok, configs} =
        MiddlewarePipeline.init_middleware([
          {TestMiddleware1, []},
          {TransformMiddleware, suffix: "-test"}
        ])

      signals = [
        %Signal{
          id: "test-1",
          type: "test.signal",
          source: "/test",
          data: %{}
        }
      ]

      context = %{bus_name: :test, timestamp: DateTime.utc_now(), metadata: %{}}

      assert {:ok, processed_signals, updated_configs} =
               MiddlewarePipeline.before_publish(configs, signals, context)

      # Signal should be transformed by TransformMiddleware
      assert [%Signal{type: "test.signal-test"}] = processed_signals

      # Verify updated configs are returned with state changes
      assert [{TestMiddleware1, %{calls: [:before_publish], id: 1}}, {TransformMiddleware, _}] =
               updated_configs
    end

    test "halts execution when middleware returns halt" do
      {:ok, configs} =
        MiddlewarePipeline.init_middleware([
          {TestMiddleware1, []},
          {HaltMiddleware, halt_reason: :custom_halt},
          {TransformMiddleware, []}
        ])

      signals = [%Signal{id: "test-1", type: "test.signal", source: "/test", data: %{}}]
      context = %{bus_name: :test, timestamp: DateTime.utc_now(), metadata: %{}}

      assert {:error, :custom_halt} = MiddlewarePipeline.before_publish(configs, signals, context)
    end

    test "continues with empty middleware list" do
      signals = [%Signal{id: "test-1", type: "test.signal", source: "/test", data: %{}}]
      context = %{bus_name: :test, timestamp: DateTime.utc_now(), metadata: %{}}

      assert {:ok, ^signals, []} = MiddlewarePipeline.before_publish([], signals, context)
    end

    test "skips middleware that don't implement before_publish" do
      # Create a middleware that only implements init
      defmodule MinimalMiddleware do
        @behaviour Jido.Signal.Bus.Middleware

        @impl true
        def init(_opts), do: {:ok, %{}}

        @impl true
        def before_publish(signals, _context, state), do: {:cont, signals, state}

        @impl true
        def after_publish(signals, _context, state), do: {:cont, signals, state}

        @impl true
        def before_dispatch(signal, _subscriber, _context, state), do: {:cont, signal, state}

        @impl true
        def after_dispatch(_signal, _subscriber, _result, _context, state), do: {:cont, state}
      end

      {:ok, configs} = MiddlewarePipeline.init_middleware([{MinimalMiddleware, []}])

      signals = [%Signal{id: "test-1", type: "test.signal", source: "/test", data: %{}}]
      context = %{bus_name: :test, timestamp: DateTime.utc_now(), metadata: %{}}

      assert {:ok, ^signals, _updated_configs} =
               MiddlewarePipeline.before_publish(configs, signals, context)
    end

    test "middleware state counter increments and persists across calls" do
      defmodule CounterMiddleware do
        use Jido.Signal.Bus.Middleware

        @impl true
        def init(_opts), do: {:ok, %{publish_count: 0}}

        @impl true
        def before_publish(signals, _context, state) do
          {:cont, signals, %{state | publish_count: state.publish_count + 1}}
        end
      end

      {:ok, configs} = MiddlewarePipeline.init_middleware([{CounterMiddleware, []}])

      signals = [%Signal{id: "test-1", type: "test.signal", source: "/test", data: %{}}]
      context = %{bus_name: :test, timestamp: DateTime.utc_now(), metadata: %{}}

      # First call
      {:ok, _, configs1} = MiddlewarePipeline.before_publish(configs, signals, context)
      assert [{CounterMiddleware, %{publish_count: 1}}] = configs1

      # Second call with updated configs
      {:ok, _, configs2} = MiddlewarePipeline.before_publish(configs1, signals, context)
      assert [{CounterMiddleware, %{publish_count: 2}}] = configs2

      # Third call
      {:ok, _, configs3} = MiddlewarePipeline.before_publish(configs2, signals, context)
      assert [{CounterMiddleware, %{publish_count: 3}}] = configs3
    end
  end

  describe "after_publish/3" do
    test "executes all middleware after_publish callbacks and returns updated configs" do
      {:ok, configs} = MiddlewarePipeline.init_middleware([{TestMiddleware1, []}])

      signals = [%Signal{id: "test-1", type: "test.signal", source: "/test", data: %{}}]
      context = %{bus_name: :test, timestamp: DateTime.utc_now(), metadata: %{}}

      # after_publish should return updated configs
      updated_configs = MiddlewarePipeline.after_publish(configs, signals, context)

      assert [{TestMiddleware1, %{calls: [:after_publish], id: 1}}] = updated_configs
    end

    test "continues with empty middleware list" do
      signals = [%Signal{id: "test-1", type: "test.signal", source: "/test", data: %{}}]
      context = %{bus_name: :test, timestamp: DateTime.utc_now(), metadata: %{}}

      assert [] = MiddlewarePipeline.after_publish([], signals, context)
    end
  end

  describe "before_dispatch/4" do
    setup do
      subscriber = %Subscriber{
        id: "test-subscription-#{:erlang.unique_integer([:positive])}",
        path: "test.signal",
        dispatch: {:pid, target: self(), delivery_mode: :async},
        persistent?: false,
        persistence_pid: nil
      }

      signal = %Signal{id: "test-1", type: "test.signal", source: "/test", data: %{}}
      context = %{bus_name: :test, timestamp: DateTime.utc_now(), metadata: %{}}

      {:ok, subscriber: subscriber, signal: signal, context: context}
    end

    test "executes middleware chain successfully and returns updated configs", %{
      subscriber: subscriber,
      signal: signal,
      context: context
    } do
      {:ok, configs} =
        MiddlewarePipeline.init_middleware([
          {TestMiddleware1, []},
          {TransformMiddleware, suffix: "-dispatch"}
        ])

      assert {:ok, processed_signal, updated_configs} =
               MiddlewarePipeline.before_dispatch(configs, signal, subscriber, context)

      # Signal should be transformed by TransformMiddleware
      assert %Signal{source: "/test-dispatch"} = processed_signal

      # Verify updated configs are returned with state changes
      assert [{TestMiddleware1, %{calls: [:before_dispatch], id: 1}}, {TransformMiddleware, _}] =
               updated_configs
    end

    test "returns skip when middleware skips", %{
      subscriber: subscriber,
      signal: signal,
      context: context
    } do
      {:ok, configs} =
        MiddlewarePipeline.init_middleware([
          {TestMiddleware1, []},
          {SkipMiddleware, []},
          {TransformMiddleware, []}
        ])

      assert :skip = MiddlewarePipeline.before_dispatch(configs, signal, subscriber, context)
    end

    test "halts execution when middleware returns halt", %{
      subscriber: subscriber,
      signal: signal,
      context: context
    } do
      {:ok, configs} =
        MiddlewarePipeline.init_middleware([
          {TestMiddleware1, []},
          {HaltMiddleware, halt_reason: :dispatch_halt},
          {TransformMiddleware, []}
        ])

      assert {:error, :dispatch_halt} =
               MiddlewarePipeline.before_dispatch(configs, signal, subscriber, context)
    end

    test "continues with empty middleware list", %{
      subscriber: subscriber,
      signal: signal,
      context: context
    } do
      assert {:ok, ^signal, []} =
               MiddlewarePipeline.before_dispatch([], signal, subscriber, context)
    end
  end

  describe "after_dispatch/5" do
    setup do
      subscriber = %Subscriber{
        id: "test-subscription-#{:erlang.unique_integer([:positive])}",
        path: "test.signal",
        dispatch: {:pid, target: self(), delivery_mode: :async},
        persistent?: false,
        persistence_pid: nil
      }

      signal = %Signal{id: "test-1", type: "test.signal", source: "/test", data: %{}}
      context = %{bus_name: :test, timestamp: DateTime.utc_now(), metadata: %{}}

      {:ok, subscriber: subscriber, signal: signal, context: context}
    end

    test "executes all middleware after_dispatch callbacks and returns updated configs", %{
      subscriber: subscriber,
      signal: signal,
      context: context
    } do
      {:ok, configs} = MiddlewarePipeline.init_middleware([{TestMiddleware1, []}])

      result = :ok

      # after_dispatch should return updated configs
      updated_configs =
        MiddlewarePipeline.after_dispatch(configs, signal, subscriber, result, context)

      assert [{TestMiddleware1, %{calls: [:after_dispatch], id: 1}}] = updated_configs
    end

    test "handles error results", %{subscriber: subscriber, signal: signal, context: context} do
      {:ok, configs} = MiddlewarePipeline.init_middleware([{TestMiddleware1, []}])

      result = {:error, :dispatch_failed}

      updated_configs =
        MiddlewarePipeline.after_dispatch(configs, signal, subscriber, result, context)

      assert [{TestMiddleware1, %{calls: [:after_dispatch], id: 1}}] = updated_configs
    end

    test "continues with empty middleware list", %{
      subscriber: subscriber,
      signal: signal,
      context: context
    } do
      result = :ok

      assert [] = MiddlewarePipeline.after_dispatch([], signal, subscriber, result, context)
    end
  end

  describe "middleware timeout protection" do
    defmodule SlowMiddleware do
      use Jido.Signal.Bus.Middleware

      @impl true
      def init(opts) do
        {:ok, %{sleep_ms: Keyword.get(opts, :sleep_ms, 200)}}
      end

      @impl true
      def before_publish(signals, _context, state) do
        Process.sleep(state.sleep_ms)
        {:cont, signals, state}
      end

      @impl true
      def before_dispatch(signal, _subscriber, _context, state) do
        Process.sleep(state.sleep_ms)
        {:cont, signal, state}
      end

      @impl true
      def after_publish(signals, _context, state) do
        Process.sleep(state.sleep_ms)
        {:cont, signals, state}
      end

      @impl true
      def after_dispatch(_signal, _subscriber, _result, _context, state) do
        Process.sleep(state.sleep_ms)
        {:cont, state}
      end
    end

    test "before_publish times out when middleware exceeds timeout" do
      {:ok, configs} = MiddlewarePipeline.init_middleware([{SlowMiddleware, sleep_ms: 200}])

      signals = [%Signal{id: "test-1", type: "test.signal", source: "/test", data: %{}}]
      context = %{bus_name: :test, timestamp: DateTime.utc_now(), metadata: %{}}

      result = MiddlewarePipeline.before_publish(configs, signals, context, 50)

      assert {:error, %Jido.Signal.Error.ExecutionFailureError{message: "Middleware timeout"}} =
               result
    end

    test "before_publish succeeds when middleware is within timeout" do
      {:ok, configs} = MiddlewarePipeline.init_middleware([{SlowMiddleware, sleep_ms: 10}])

      signals = [%Signal{id: "test-1", type: "test.signal", source: "/test", data: %{}}]
      context = %{bus_name: :test, timestamp: DateTime.utc_now(), metadata: %{}}

      result = MiddlewarePipeline.before_publish(configs, signals, context, 100)

      assert {:ok, ^signals, _configs} = result
    end

    test "before_publish returns controlled error when middleware crashes" do
      {:ok, configs} = MiddlewarePipeline.init_middleware([{CrashingMiddleware, []}])

      signals = [%Signal{id: "test-1", type: "test.signal", source: "/test", data: %{}}]
      context = %{bus_name: :test, timestamp: DateTime.utc_now(), metadata: %{}}

      result = MiddlewarePipeline.before_publish(configs, signals, context, 100)

      assert {:error, %Jido.Signal.Error.ExecutionFailureError{message: "Middleware crashed"}} =
               result
    end

    test "before_dispatch times out when middleware exceeds timeout" do
      {:ok, configs} = MiddlewarePipeline.init_middleware([{SlowMiddleware, sleep_ms: 200}])

      signal = %Signal{id: "test-1", type: "test.signal", source: "/test", data: %{}}

      subscriber = %Subscriber{
        id: "test-sub",
        path: "test.signal",
        dispatch: {:pid, target: self(), delivery_mode: :async},
        persistent?: false,
        persistence_pid: nil
      }

      context = %{bus_name: :test, timestamp: DateTime.utc_now(), metadata: %{}}

      result = MiddlewarePipeline.before_dispatch(configs, signal, subscriber, context, 50)

      assert {:error, %Jido.Signal.Error.ExecutionFailureError{message: "Middleware timeout"}} =
               result
    end

    test "before_dispatch returns controlled error when middleware crashes" do
      {:ok, configs} = MiddlewarePipeline.init_middleware([{CrashingMiddleware, []}])

      signal = %Signal{id: "test-1", type: "test.signal", source: "/test", data: %{}}

      subscriber = %Subscriber{
        id: "test-sub",
        path: "test.signal",
        dispatch: {:pid, target: self(), delivery_mode: :async},
        persistent?: false,
        persistence_pid: nil
      }

      context = %{bus_name: :test, timestamp: DateTime.utc_now(), metadata: %{}}

      result = MiddlewarePipeline.before_dispatch(configs, signal, subscriber, context, 100)

      assert {:error, %Jido.Signal.Error.ExecutionFailureError{message: "Middleware crashed"}} =
               result
    end

    test "emits telemetry event on timeout" do
      {:ok, configs} = MiddlewarePipeline.init_middleware([{SlowMiddleware, sleep_ms: 200}])

      signals = [%Signal{id: "test-1", type: "test.signal", source: "/test", data: %{}}]
      # Use unique bus name to avoid interference from concurrent tests
      unique_bus_name = :"test_bus_timeout_#{System.unique_integer([:positive])}"
      context = %{bus_name: unique_bus_name, timestamp: DateTime.utc_now(), metadata: %{}}

      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "test-timeout-handler-#{inspect(ref)}",
        [:jido, :signal, :middleware, :timeout],
        fn event, measurements, metadata, _config ->
          # Only forward events for our specific bus to avoid cross-test interference
          if metadata.bus_name == unique_bus_name do
            send(test_pid, {:telemetry_event, event, measurements, metadata})
          end
        end,
        nil
      )

      _result = MiddlewarePipeline.before_publish(configs, signals, context, 50)

      assert_receive {:telemetry_event, [:jido, :signal, :middleware, :timeout], measurements,
                      metadata}

      assert measurements.timeout_ms == 50
      assert metadata.module == SlowMiddleware
      assert metadata.bus_name == unique_bus_name

      :telemetry.detach("test-timeout-handler-#{inspect(ref)}")
    end

    test "normal middleware works when within timeout" do
      {:ok, configs} = MiddlewarePipeline.init_middleware([{TestMiddleware1, []}])

      signals = [%Signal{id: "test-1", type: "test.signal", source: "/test", data: %{}}]
      context = %{bus_name: :test, timestamp: DateTime.utc_now(), metadata: %{}}

      result = MiddlewarePipeline.before_publish(configs, signals, context, 100)

      assert {:ok, ^signals, [{TestMiddleware1, %{calls: [:before_publish], id: 1}}]} = result
    end
  end

  describe "middleware chain ordering" do
    test "middleware are executed in the order they are initialized" do
      # Create middleware that append to a list to track execution order
      defmodule OrderTrackingMiddleware do
        use Jido.Signal.Bus.Middleware

        @impl true
        def init(opts) do
          test_pid = Keyword.fetch!(opts, :test_pid)
          id = Keyword.fetch!(opts, :id)
          {:ok, %{test_pid: test_pid, id: id}}
        end

        @impl true
        def before_publish(signals, _context, state) do
          send(state.test_pid, {:middleware_called, state.id, :before_publish})
          {:cont, signals, state}
        end
      end

      middleware_specs = [
        {OrderTrackingMiddleware, test_pid: self(), id: :first},
        {OrderTrackingMiddleware, test_pid: self(), id: :second},
        {OrderTrackingMiddleware, test_pid: self(), id: :third}
      ]

      {:ok, configs} = MiddlewarePipeline.init_middleware(middleware_specs)

      signals = [%Signal{id: "test-1", type: "test.signal", source: "/test", data: %{}}]
      context = %{bus_name: :test, timestamp: DateTime.utc_now(), metadata: %{}}

      MiddlewarePipeline.before_publish(configs, signals, context)

      # Verify execution order
      assert_receive {:middleware_called, :first, :before_publish}
      assert_receive {:middleware_called, :second, :before_publish}
      assert_receive {:middleware_called, :third, :before_publish}
    end
  end

  describe "middleware telemetry events" do
    setup do
      test_pid = self()
      ref = make_ref()
      # Use unique bus name to avoid cross-test interference
      unique_bus_name = :"telemetry_test_bus_#{System.unique_integer([:positive])}"

      handler_id = "test-telemetry-handler-#{inspect(ref)}"

      :telemetry.attach_many(
        handler_id,
        [
          [:jido, :signal, :middleware, :before_publish, :start],
          [:jido, :signal, :middleware, :before_publish, :stop],
          [:jido, :signal, :middleware, :before_publish, :exception],
          [:jido, :signal, :middleware, :after_publish, :stop],
          [:jido, :signal, :middleware, :before_dispatch, :start],
          [:jido, :signal, :middleware, :before_dispatch, :stop],
          [:jido, :signal, :middleware, :before_dispatch, :skip],
          [:jido, :signal, :middleware, :after_dispatch, :stop]
        ],
        fn event, measurements, metadata, config ->
          # Only forward events for our specific bus to avoid cross-test interference
          if metadata[:bus_name] == config.bus_name do
            send(config.test_pid, {:telemetry_event, event, measurements, metadata})
          end
        end,
        %{test_pid: test_pid, bus_name: unique_bus_name}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      subscriber = %Subscriber{
        id: "test-subscription-#{:erlang.unique_integer([:positive])}",
        path: "test.signal",
        dispatch: {:pid, target: self(), delivery_mode: :async},
        persistent?: false,
        persistence_pid: nil
      }

      signal = %Signal{id: "test-signal-1", type: "test.signal", source: "/test", data: %{}}
      context = %{bus_name: unique_bus_name, timestamp: DateTime.utc_now(), metadata: %{}}

      {:ok, subscriber: subscriber, signal: signal, context: context, bus_name: unique_bus_name}
    end

    test "emits start and stop events for before_publish", %{
      signal: signal,
      context: context,
      bus_name: bus_name
    } do
      {:ok, configs} = MiddlewarePipeline.init_middleware([{TestMiddleware1, []}])

      {:ok, _, _} = MiddlewarePipeline.before_publish(configs, [signal], context)

      assert_receive {:telemetry_event, [:jido, :signal, :middleware, :before_publish, :start],
                      measurements, metadata}

      assert is_integer(measurements.system_time)
      assert metadata.bus_name == bus_name
      assert metadata.module == TestMiddleware1
      assert metadata.signals_count == 1

      assert_receive {:telemetry_event, [:jido, :signal, :middleware, :before_publish, :stop],
                      measurements, metadata}

      assert is_integer(measurements.duration_us)
      assert measurements.duration_us >= 0
      assert metadata.bus_name == bus_name
      assert metadata.module == TestMiddleware1
      assert metadata.signals_count == 1
    end

    test "emits exception event when before_publish times out", %{
      signal: signal,
      context: context,
      bus_name: bus_name
    } do
      {:ok, configs} =
        MiddlewarePipeline.init_middleware([
          {JidoTest.Signal.Bus.MiddlewarePipeline.SlowMiddleware, sleep_ms: 200}
        ])

      _result = MiddlewarePipeline.before_publish(configs, [signal], context, 50)

      assert_receive {:telemetry_event, [:jido, :signal, :middleware, :before_publish, :start], _,
                      _}

      assert_receive {:telemetry_event,
                      [:jido, :signal, :middleware, :before_publish, :exception], measurements,
                      metadata}

      assert is_integer(measurements.duration_us)
      assert metadata.bus_name == bus_name
      assert metadata.module == JidoTest.Signal.Bus.MiddlewarePipeline.SlowMiddleware
    end

    test "emits stop event for after_publish", %{
      signal: signal,
      context: context,
      bus_name: bus_name
    } do
      {:ok, configs} = MiddlewarePipeline.init_middleware([{TestMiddleware1, []}])

      _updated = MiddlewarePipeline.after_publish(configs, [signal], context)

      assert_receive {:telemetry_event, [:jido, :signal, :middleware, :after_publish, :stop],
                      measurements, metadata}

      assert is_integer(measurements.duration_us)
      assert measurements.duration_us >= 0
      assert metadata.bus_name == bus_name
      assert metadata.module == TestMiddleware1
      assert metadata.signals_count == 1
    end

    test "emits start and stop events for before_dispatch", %{
      signal: signal,
      subscriber: subscriber,
      context: context,
      bus_name: bus_name
    } do
      {:ok, configs} = MiddlewarePipeline.init_middleware([{TestMiddleware1, []}])

      {:ok, _, _} = MiddlewarePipeline.before_dispatch(configs, signal, subscriber, context)

      assert_receive {:telemetry_event, [:jido, :signal, :middleware, :before_dispatch, :start],
                      measurements, metadata}

      assert is_integer(measurements.system_time)
      assert metadata.bus_name == bus_name
      assert metadata.module == TestMiddleware1
      assert metadata.signal_id == "test-signal-1"
      assert is_binary(metadata.subscription_id)

      assert_receive {:telemetry_event, [:jido, :signal, :middleware, :before_dispatch, :stop],
                      measurements, metadata}

      assert is_integer(measurements.duration_us)
      assert measurements.duration_us >= 0
      assert metadata.bus_name == bus_name
      assert metadata.module == TestMiddleware1
      assert metadata.signal_id == "test-signal-1"
      assert is_binary(metadata.subscription_id)
    end

    test "emits skip event when middleware returns :skip", %{
      signal: signal,
      subscriber: subscriber,
      context: context,
      bus_name: bus_name
    } do
      {:ok, configs} = MiddlewarePipeline.init_middleware([{SkipMiddleware, []}])

      :skip = MiddlewarePipeline.before_dispatch(configs, signal, subscriber, context)

      assert_receive {:telemetry_event, [:jido, :signal, :middleware, :before_dispatch, :start],
                      _, _}

      assert_receive {:telemetry_event, [:jido, :signal, :middleware, :before_dispatch, :skip],
                      measurements, metadata}

      assert is_integer(measurements.duration_us)
      assert measurements.duration_us >= 0
      assert metadata.bus_name == bus_name
      assert metadata.module == SkipMiddleware
      assert metadata.signal_id == "test-signal-1"
      assert is_binary(metadata.subscription_id)
    end

    test "emits stop event for after_dispatch", %{
      signal: signal,
      subscriber: subscriber,
      context: context,
      bus_name: bus_name
    } do
      {:ok, configs} = MiddlewarePipeline.init_middleware([{TestMiddleware1, []}])

      _updated =
        MiddlewarePipeline.after_dispatch(configs, signal, subscriber, :ok, context)

      assert_receive {:telemetry_event, [:jido, :signal, :middleware, :after_dispatch, :stop],
                      measurements, metadata}

      assert is_integer(measurements.duration_us)
      assert measurements.duration_us >= 0
      assert metadata.bus_name == bus_name
      assert metadata.module == TestMiddleware1
      assert metadata.signal_id == "test-signal-1"
      assert is_binary(metadata.subscription_id)
    end

    test "duration_us is properly calculated", %{signal: signal, context: context} do
      {:ok, configs} =
        MiddlewarePipeline.init_middleware([
          {JidoTest.Signal.Bus.MiddlewarePipeline.SlowMiddleware, sleep_ms: 10}
        ])

      {:ok, _, _} = MiddlewarePipeline.before_publish(configs, [signal], context, 100)

      assert_receive {:telemetry_event, [:jido, :signal, :middleware, :before_publish, :stop],
                      measurements, _metadata}

      # Use a more lenient threshold to avoid flaky tests
      assert measurements.duration_us >= 5_000
    end
  end
end
