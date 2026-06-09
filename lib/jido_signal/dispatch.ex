defmodule Jido.Signal.Dispatch do
  @moduledoc """
  A flexible signal dispatching system that routes signals to various destinations using configurable adapters.

  The Dispatch module serves as the central hub for signal delivery in the Jido system. It provides a unified
  interface for sending signals to different destinations through various adapters. Each adapter implements
  specific delivery mechanisms suited for different use cases.

  ## Built-in Adapters

  The following adapters are provided out of the box:

  * `:pid` - Direct delivery to a specific process (see `Jido.Signal.Dispatch.PidAdapter`)
  * `:bus` - Delivery to a signal bus via `Jido.Signal.Bus`
  * `:named` - Delivery to a named process (see `Jido.Signal.Dispatch.Named`)
  * `:pubsub` - Delivery via PubSub mechanism (see `Jido.Signal.Dispatch.PubSub`)
  * `:logger` - Log signals using Logger (see `Jido.Signal.Dispatch.LoggerAdapter`)
  * `:console` - Print signals to console (see `Jido.Signal.Dispatch.ConsoleAdapter`)
  * `:noop` - No-op adapter for testing/development (see `Jido.Signal.Dispatch.NoopAdapter`)
  * `:http` - HTTP requests using :httpc (see `Jido.Signal.Dispatch.Http`)
  * `:webhook` - Webhook delivery with signatures (see `Jido.Signal.Dispatch.Webhook`)

  ## Configuration

  Each adapter requires specific configuration options. A dispatch configuration is a tuple of
  `{adapter_type, options}` where:

  * `adapter_type` - One of the built-in adapter types above or a custom module implementing the `Jido.Signal.Dispatch.Adapter` behaviour
  * `options` - Keyword list of options specific to the chosen adapter

  Multiple dispatch configurations can be provided as a list to send signals to multiple destinations.

  ## Dispatch Modes

  The module supports three dispatch modes:

  1. Synchronous (via `dispatch/2`) - Fire-and-forget dispatch that returns when all dispatches complete
  2. Asynchronous (via `dispatch_async/2`) - Returns immediately with a task that can be monitored
  3. Batched (via `dispatch_batch/3`) - Handles large numbers of dispatches in configurable batches

  ## Concurrency

  When dispatching to multiple targets (via a list of configs), the dispatch system processes
  them in parallel using `Task.Supervisor.async_stream/3`. The maximum concurrency can be
  configured at compile-time or runtime:

      # In config.exs (compile-time)
      config :jido, :dispatch_max_concurrency, 16

      # Default: 8 concurrent dispatches

  This parallel processing significantly improves throughput for multiple targets. For example,
  dispatching to 10 targets with 100ms latency each completes in ~200ms (with default concurrency)
  instead of ~1000ms sequentially.

  ## Error Handling

  **BREAKING CHANGE in behavior:** When dispatching to multiple targets (list of configs),
  `dispatch/2` now aggregates all errors instead of returning only the first error:

  - Single config: `dispatch(signal, config)` returns `:ok` or `{:error, reason}`
  - Multiple configs: `dispatch(signal, configs)` returns `:ok` or `{:error, [reason1, reason2, ...]}`

  The batch dispatch function `dispatch_batch/3` continues to return indexed errors as before:
  `{:error, [{index, reason}, ...]}`.

  ## Runtime Options

  Runtime options are passed separately from adapter configuration:

  * `:task_supervisor` - Task supervisor used for async and parallel dispatch work.
  * `:circuit_breaker_server` - Circuit breaker server used by built-in HTTP and webhook dispatch.

  ## Reserved Options

  The following option keys are reserved for internal use and are stripped from dispatch configurations:

  * `:__validated__`

  ## Deprecated

  * `batch_size` option in `dispatch_batch/3` - Kept for backwards compatibility but no longer used.
    All dispatches now use the same parallel processing with `max_concurrency` control.

  ## Examples

      # Synchronous dispatch
      config = {:pid, [target: pid, delivery_mode: :async]}
      :ok = Dispatch.dispatch(signal, config)

      # Asynchronous dispatch
      {:ok, task} = Dispatch.dispatch_async(signal, config)
      :ok = Task.await(task)

      # Batch dispatch
      configs = List.duplicate({:pid, [target: pid]}, 1000)
      :ok = Dispatch.dispatch_batch(signal, configs, max_concurrency: 20)

      # Multiple targets with parallel dispatch
      configs = [
        {:pid, [target: pid1]},
        {:http, [url: "https://api.example.com/webhook"]},
        {:pubsub, [target: :my_pubsub, topic: "events"]}
      ]
      # Returns :ok or {:error, [error1, error2, ...]}
      Dispatch.dispatch(signal, configs)

      # HTTP dispatch
      config = {:http, [
        url: "https://api.example.com/events",
        method: :post,
        headers: [{"x-api-key", "secret"}]
      ]}
      :ok = Dispatch.dispatch(signal, config)

      # Webhook dispatch
      config = {:webhook, [
        url: "https://api.example.com/webhook",
        secret: "webhook_secret",
        event_type_map: %{"user:created" => "user.created"}
      ]}
      :ok = Dispatch.dispatch(signal, config)
  """

  alias Jido.Signal.Dispatch.CircuitBreaker
  alias Jido.Signal.Error
  alias Jido.Signal.Telemetry

  @type adapter ::
          :pid
          | :bus
          | :named
          | :pubsub
          | :logger
          | :console
          | :noop
          | :http
          | :webhook
          | nil
          | module()
  @type dispatch_config :: {adapter(), Keyword.t()}
  @type dispatch_configs :: dispatch_config() | [dispatch_config()]
  @type runtime_opts :: [
          task_supervisor: pid() | atom(),
          circuit_breaker_server: atom()
        ]
  @type batch_opts :: [
          batch_size: pos_integer(),
          max_concurrency: pos_integer(),
          task_supervisor: pid() | atom(),
          circuit_breaker_server: atom()
        ]

  @default_batch_size 50
  @default_max_concurrency 5
  @default_dispatch_max_concurrency Application.compile_env(
                                      :jido,
                                      :dispatch_max_concurrency,
                                      8
                                    )
  @normalize_errors_compile_time Application.compile_env(
                                   :jido,
                                   :normalize_dispatch_errors,
                                   false
                                 )

  @builtin_adapters %{
    pid: Jido.Signal.Dispatch.PidAdapter,
    named: Jido.Signal.Dispatch.Named,
    pubsub: Jido.Signal.Dispatch.PubSub,
    bus: Jido.Signal.Dispatch.Bus,
    logger: Jido.Signal.Dispatch.LoggerAdapter,
    console: Jido.Signal.Dispatch.ConsoleAdapter,
    noop: Jido.Signal.Dispatch.NoopAdapter,
    http: Jido.Signal.Dispatch.Http,
    webhook: Jido.Signal.Dispatch.Webhook
  }

  @doc """
  Validates a dispatch configuration without executing the dispatch.

  This is useful for pre-validating configurations before dispatch time, or for testing
  adapter configurations. Validation is automatically performed during dispatch, but
  this function allows explicit validation for debugging or testing purposes.

  ## Parameters

  - `config` - Either a single dispatch configuration tuple or a list of dispatch configurations

  ## Returns

  - `{:ok, config}` if the configuration is valid
  - `{:error, reason}` if the configuration is invalid

  ## Examples

      # Single config
      iex> config = {:pid, [target: self(), delivery_mode: :async]}
      iex> Jido.Signal.Dispatch.validate_opts(config)
      {:ok, ^config}

      # Multiple configs
      iex> config = [
      ...>   {:bus, [target: :default_bus]},
      ...>   {:pubsub, [target: :audit_pubsub, topic: "audit"]}
      ...> ]
      iex> Jido.Signal.Dispatch.validate_opts(config)
      {:ok, ^config}

      # Pre-validation for testing
      {:ok, validated} = Dispatch.validate_opts({:pid, [target: pid]})
      # Use validated config later...
  """
  @spec validate_opts(dispatch_configs()) :: {:ok, dispatch_configs()} | {:error, term()}
  # Handle single dispatcher config
  def validate_opts({adapter, opts} = config) when is_atom(adapter) and is_list(opts) do
    case validate_single_config(config) do
      {:ok, {adapter, validated_opts}} ->
        # Remove internal marker before returning to user
        {:ok, {adapter, Keyword.delete(validated_opts, :__validated__)}}

      error ->
        error
    end
  end

  # Handle list of dispatchers
  def validate_opts(configs) when is_list(configs) do
    results = Enum.map(configs, &validate_single_config/1)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        cleaned_results =
          Enum.map(results, fn {:ok, {adapter, opts}} ->
            {adapter, Keyword.delete(opts, :__validated__)}
          end)

        {:ok, cleaned_results}

      error ->
        error
    end
  end

  def validate_opts(invalid_config) do
    if should_normalize_errors?() do
      {:error,
       Error.validation_error(
         "Invalid dispatch configuration",
         %{field: "dispatch_config", value: invalid_config, reason: :invalid_dispatch_config}
       )}
    else
      {:error, :invalid_dispatch_config}
    end
  end

  @doc """
  Dispatches a signal using the provided configuration.

  This is a synchronous operation that returns when all dispatches complete.
  For asynchronous dispatch, use `dispatch_async/2`.
  For batch dispatch, use `dispatch_batch/3`.

  When dispatching to multiple targets (list of configs), dispatches are executed in parallel
  with configurable concurrency (default: 8 concurrent tasks).

  ## Parameters

  - `signal` - The signal to dispatch
  - `config` - Either a single dispatch configuration tuple or a list of configurations

  ## Returns

  - `:ok` - All dispatches succeeded
  - `{:error, reason}` - Single config dispatch failed
  - `{:error, [reason1, reason2, ...]}` - One or more multi-config dispatches failed (aggregated errors)

  ## Examples

      # Single destination
      iex> config = {:pid, [target: pid, delivery_mode: :async]}
      iex> Jido.Signal.Dispatch.dispatch(signal, config)
      :ok

      # Multiple destinations (executed in parallel)
      iex> config = [
      ...>   {:bus, [target: :default_bus]},
      ...>   {:pubsub, [target: :audit, topic: "audit"]}
      ...> ]
      iex> Jido.Signal.Dispatch.dispatch(signal, config)
      :ok

      # Error aggregation for multiple targets
      iex> config = [
      ...>   {:pid, [target: pid1]},
      ...>   {:invalid_adapter, []},
      ...>   {:pid, [target: pid2]}
      ...> ]
      iex> Jido.Signal.Dispatch.dispatch(signal, config)
      {:error, [%Jido.Signal.Error{...}]}
  """
  @spec dispatch(Jido.Signal.t(), dispatch_configs()) :: :ok | {:error, term()}
  @spec dispatch(Jido.Signal.t(), dispatch_configs(), runtime_opts()) :: :ok | {:error, term()}
  def dispatch(signal, config) do
    dispatch(signal, config, [])
  end

  # Handle single dispatcher
  def dispatch(signal, {adapter, opts} = config, runtime_opts)
      when is_atom(adapter) and is_list(opts) do
    dispatch_single(signal, config, runtime_opts)
  end

  # Handle multiple dispatchers
  def dispatch(signal, configs, runtime_opts) when is_list(configs) do
    task_supervisor = task_supervisor(runtime_opts)

    results =
      Task.Supervisor.async_stream(
        task_supervisor,
        configs,
        fn config -> dispatch_single(signal, config, runtime_opts) end,
        max_concurrency: @default_dispatch_max_concurrency,
        ordered: true,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:error, reason}
      end)

    # Collect ALL errors instead of returning first error
    errors =
      Enum.filter(results, &match?({:error, _}, &1))
      |> Enum.map(fn {:error, reason} -> reason end)

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end

  def dispatch(_signal, _config, _runtime_opts) do
    {:error, :invalid_dispatch_config}
  end

  @doc """
  Dispatches a signal asynchronously using the provided configuration.

  Returns immediately with a task that can be monitored for completion.

  ## Parameters

  - `signal` - The signal to dispatch
  - `config` - Either a single dispatch configuration tuple or a list of configurations

  ## Returns

  - `{:ok, task}` where task is a Task that can be awaited
  - `{:error, reason}` if the configuration is invalid

  ## Examples

      {:ok, task} = Dispatch.dispatch_async(signal, config)
      :ok = Task.await(task)
  """
  @spec dispatch_async(Jido.Signal.t(), dispatch_configs()) :: {:ok, Task.t()} | {:error, term()}
  @spec dispatch_async(Jido.Signal.t(), dispatch_configs(), runtime_opts()) ::
          {:ok, Task.t()} | {:error, term()}
  def dispatch_async(signal, config) do
    dispatch_async(signal, config, [])
  end

  def dispatch_async(signal, config, runtime_opts) do
    task_supervisor = task_supervisor(runtime_opts)

    case validate_opts(config) do
      {:ok, validated_config} ->
        task =
          Task.Supervisor.async_nolink(task_supervisor, fn ->
            dispatch(signal, validated_config, runtime_opts)
          end)

        {:ok, task}

      error ->
        error
    end
  end

  @doc """
  Dispatches a signal to multiple destinations in batches.

  This is useful when dispatching to a large number of destinations to avoid
  overwhelming the system. The dispatches are processed with configurable concurrency.

  ## Parameters

  - `signal` - The signal to dispatch
  - `configs` - List of dispatch configurations
  - `opts` - Batch options:
    * `:batch_size` - **Deprecated** (kept for backwards compatibility, no longer used)
    * `:max_concurrency` - Maximum number of concurrent dispatches (default: #{@default_max_concurrency})

  ## Returns

  - `:ok` if all dispatches succeed
  - `{:error, errors}` where errors is a list of `{index, reason}` tuples

  ## Examples

      configs = List.duplicate({:pid, [target: pid]}, 1000)
      :ok = Dispatch.dispatch_batch(signal, configs, max_concurrency: 20)
  """
  @spec dispatch_batch(Jido.Signal.t(), [dispatch_config()], batch_opts()) ::
          :ok | {:error, [{non_neg_integer(), term()}]}
  def dispatch_batch(signal, configs, opts \\ []) when is_list(configs) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    max_concurrency = Keyword.get(opts, :max_concurrency, @default_max_concurrency)
    task_supervisor = Keyword.get(opts, :task_supervisor, Jido.Signal.TaskSupervisor)
    runtime_opts = Keyword.take(opts, [:circuit_breaker_server])

    validation_results = validate_configs_with_index(configs)
    {valid_configs, validation_errors} = split_validation_results(validation_results)

    validated_configs_with_idx = extract_validated_configs(valid_configs)

    dispatch_results =
      process_batches(
        signal,
        validated_configs_with_idx,
        batch_size,
        max_concurrency,
        task_supervisor,
        runtime_opts
      )

    validation_errors = extract_validation_errors(validation_errors)
    dispatch_errors = extract_dispatch_errors(dispatch_results)

    combine_results(validation_errors, dispatch_errors)
  end

  # Batch processing helpers

  defp validate_configs_with_index(configs) do
    configs_with_index = Enum.with_index(configs)

    Enum.map(configs_with_index, fn {config, idx} ->
      case validate_single_config(config) do
        {:ok, validated_config} -> {:ok, {validated_config, idx}}
        {:error, reason} -> {:error, {idx, reason}}
      end
    end)
  end

  defp split_validation_results(validation_results) do
    Enum.split_with(validation_results, fn
      {:ok, _} -> true
      {:error, _} -> false
    end)
  end

  defp extract_validated_configs(valid_configs) do
    Enum.map(valid_configs, fn {:ok, {config, idx}} -> {config, idx} end)
  end

  defp process_batches(
         signal,
         validated_configs_with_idx,
         _batch_size,
         max_concurrency,
         task_supervisor,
         runtime_opts
       ) do
    # Single stream over all configs (batch_size is now a no-op for backwards compat)
    Task.Supervisor.async_stream(
      task_supervisor,
      validated_configs_with_idx,
      fn {config, original_idx} ->
        case dispatch_validated_single(signal, config, runtime_opts) do
          :ok -> {:ok, original_idx}
          {:error, reason} -> {:error, {original_idx, reason}}
        end
      end,
      max_concurrency: max_concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp extract_validation_errors(validation_errors) do
    Enum.map(validation_errors, fn {:error, error} -> error end)
  end

  defp extract_dispatch_errors(dispatch_results) do
    Enum.reduce(dispatch_results, [], fn
      {:error, error}, acc -> [error | acc]
      {:ok, _}, acc -> acc
    end)
  end

  defp combine_results(validation_errors, dispatch_errors) do
    case {validation_errors, dispatch_errors} do
      {[], []} -> :ok
      {errors, []} -> {:error, Enum.reverse(errors)}
      {[], errors} -> {:error, Enum.reverse(errors)}
      {val_errs, disp_errs} -> {:error, Enum.reverse(val_errs ++ disp_errs)}
    end
  end

  defp task_supervisor(runtime_opts) when is_list(runtime_opts) do
    Keyword.get(runtime_opts, :task_supervisor, Jido.Signal.TaskSupervisor)
  end

  # Private helpers

  defp normalize_error(reason, adapter, config) when is_atom(reason) do
    if should_normalize_errors?() do
      {:error,
       Error.dispatch_error(
         "Signal dispatch failed",
         %{adapter: adapter, reason: reason, config: config}
       )}
    else
      {:error, reason}
    end
  end

  defp normalize_error(reason, adapter, config) do
    if should_normalize_errors?() do
      {:error,
       Error.dispatch_error(
         "Signal dispatch failed",
         %{adapter: adapter, reason: reason, config: config}
       )}
    else
      {:error, reason}
    end
  end

  defp normalize_validation_error(reason, adapter, config) when is_atom(reason) do
    if should_normalize_errors?() do
      {:error,
       Error.validation_error(
         "Invalid adapter configuration",
         %{field: "config", value: config, adapter: adapter, reason: reason}
       )}
    else
      {:error, reason}
    end
  end

  defp normalize_validation_error(reason, adapter, config) do
    if should_normalize_errors?() do
      {:error,
       Error.validation_error(
         "Invalid adapter configuration",
         %{field: "config", value: config, adapter: adapter, reason: reason}
       )}
    else
      {:error, reason}
    end
  end

  defp should_normalize_errors? do
    Application.get_env(
      :jido_signal,
      :normalize_dispatch_errors,
      Application.get_env(:jido, :normalize_dispatch_errors, @normalize_errors_compile_time)
    )
  end

  defp validate_single_config({nil, opts}) when is_list(opts) do
    {:ok, {nil, strip_internal_opts(opts)}}
  end

  defp validate_single_config({adapter, opts}) when is_atom(adapter) and is_list(opts) do
    opts = strip_internal_opts(opts)

    with {:ok, adapter_module} <- resolve_adapter(adapter),
         {:ok, validated_opts} <- adapter_module.validate_opts(opts) do
      {:ok, {adapter, validated_opts}}
    else
      {:error, reason} -> normalize_validation_error(reason, adapter, {adapter, opts})
    end
  end

  defp dispatch_single(_signal, {nil, _opts}, _runtime_opts), do: :ok

  defp dispatch_single(signal, {adapter, opts}, runtime_opts) do
    with_dispatch_telemetry(signal, adapter, opts, fn ->
      do_dispatch_single(signal, {adapter, opts}, runtime_opts)
    end)
  end

  defp dispatch_validated_single(signal, {adapter, opts}, runtime_opts) do
    with_dispatch_telemetry(signal, adapter, opts, fn ->
      do_dispatch_validated_single(signal, {adapter, opts}, runtime_opts)
    end)
  end

  defp with_dispatch_telemetry(signal, adapter, opts, dispatch_fun) do
    start_time = System.monotonic_time(:millisecond)
    metadata = dispatch_telemetry_metadata(signal, adapter, opts)

    Telemetry.execute([:jido, :dispatch, :start], %{}, metadata)

    result = dispatch_fun.()
    measurements = %{latency_ms: System.monotonic_time(:millisecond) - start_time}

    if match?(:ok, result) do
      Telemetry.execute(
        [:jido, :dispatch, :stop],
        measurements,
        dispatch_success_metadata(metadata)
      )
    else
      Telemetry.execute(
        [:jido, :dispatch, :exception],
        measurements,
        dispatch_failure_metadata(metadata, result, adapter, opts)
      )
    end

    result
  end

  defp do_dispatch_single(signal, {adapter, opts}, runtime_opts) do
    case resolve_adapter(adapter) do
      {:ok, adapter_module} ->
        do_dispatch_with_adapter(signal, adapter_module, {adapter, opts}, runtime_opts)

      {:error, reason} ->
        normalize_error(reason, adapter, {adapter, opts})
    end
  end

  defp do_dispatch_validated_single(_signal, {nil, _opts}, _runtime_opts), do: :ok

  defp do_dispatch_validated_single(signal, {adapter, opts}, runtime_opts) do
    case resolve_adapter(adapter) do
      {:ok, adapter_module} ->
        dispatch_deliver(signal, adapter_module, adapter, opts, runtime_opts)

      {:error, reason} ->
        normalize_error(reason, adapter, {adapter, opts})
    end
  end

  defp do_dispatch_with_adapter(signal, adapter_module, {adapter, opts}, runtime_opts) do
    opts = strip_internal_opts(opts)

    case adapter_module.validate_opts(opts) do
      {:ok, validated_opts} ->
        dispatch_deliver(signal, adapter_module, adapter, validated_opts, runtime_opts)

      {:error, reason} ->
        normalize_error(reason, adapter, {adapter, opts})
    end
  end

  defp strip_internal_opts(opts), do: Keyword.delete(opts, :__validated__)

  defp dispatch_deliver(signal, adapter_module, adapter, opts, runtime_opts) do
    deliver = fn ->
      case adapter_module.deliver(signal, opts) do
        :ok -> :ok
        {:error, reason} -> normalize_error(reason, adapter, {adapter, opts})
      end
    end

    with_circuit_breaker(adapter, opts, runtime_opts, deliver)
  end

  defp with_circuit_breaker(adapter, opts, runtime_opts, deliver)
       when adapter in [:http, :webhook] do
    breaker_opts = [server: circuit_breaker_server(runtime_opts)]

    case CircuitBreaker.ensure_installed(adapter, breaker_opts) do
      :ok ->
        adapter
        |> CircuitBreaker.run(deliver, breaker_opts)
        |> normalize_circuit_result(adapter, opts)

      {:error, reason} ->
        normalize_error(reason, adapter, {adapter, opts})
    end
  end

  defp with_circuit_breaker(_adapter, _opts, _runtime_opts, deliver), do: deliver.()

  defp normalize_circuit_result({:error, %Error.DispatchError{}} = error, _adapter, _opts),
    do: error

  defp normalize_circuit_result({:error, reason}, adapter, opts),
    do: normalize_error(reason, adapter, {adapter, opts})

  defp normalize_circuit_result(result, _adapter, _opts), do: result

  defp circuit_breaker_server(runtime_opts) do
    Keyword.get(runtime_opts, :circuit_breaker_server, CircuitBreaker.Server)
  end

  defp dispatch_telemetry_metadata(signal, adapter, opts) do
    %{
      adapter: adapter,
      runtime_surface: :dispatch,
      signal_type: signal_type(signal),
      target: get_target_from_opts(opts),
      target_kind: target_kind(opts)
    }
  end

  defp dispatch_success_metadata(metadata),
    do: Map.merge(metadata, %{outcome: :ok, success?: true})

  defp dispatch_failure_metadata(metadata, {:error, reason}, adapter, opts) do
    error = dispatch_error_for_telemetry(reason, adapter, {adapter, opts})

    Map.merge(metadata, %{
      outcome: :error,
      retry_count: 0,
      success?: false,
      error_type: Error.type(error),
      retryable?: Error.retryable?(error)
    })
  end

  defp dispatch_failure_metadata(metadata, _result, _adapter, _opts),
    do: Map.merge(metadata, %{outcome: :error, success?: false})

  defp signal_type(%{type: type}) when is_binary(type), do: type
  defp signal_type(_signal), do: :unknown

  defp get_target_from_opts(opts) do
    cond do
      target = Keyword.get(opts, :target) -> target
      url = Keyword.get(opts, :url) -> url_target_for_telemetry(url)
      pid = Keyword.get(opts, :pid) -> pid
      name = Keyword.get(opts, :name) -> name
      topic = Keyword.get(opts, :topic) -> topic
      true -> :unknown
    end
  end

  defp url_target_for_telemetry(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        uri
        |> Map.put(:userinfo, nil)
        |> Map.put(:query, nil)
        |> Map.put(:fragment, nil)
        |> URI.to_string()

      _ ->
        :invalid_url
    end
  end

  defp url_target_for_telemetry(_url), do: :invalid_url

  defp target_kind(opts) do
    cond do
      Keyword.has_key?(opts, :url) -> :url
      Keyword.has_key?(opts, :topic) -> :topic
      Keyword.has_key?(opts, :pid) -> :pid
      match?({:name, _}, Keyword.get(opts, :target)) -> :name
      is_pid(Keyword.get(opts, :target)) -> :pid
      Keyword.has_key?(opts, :target) -> :target
      true -> :unknown
    end
  end

  defp dispatch_error_for_telemetry(%Error.DispatchError{} = error, _adapter, _config), do: error

  defp dispatch_error_for_telemetry(reason, adapter, config) do
    Error.dispatch_error("Signal dispatch failed", %{
      adapter: adapter,
      reason: reason,
      config: config
    })
  end

  defp resolve_adapter(adapter) when is_atom(adapter) do
    case Map.fetch(@builtin_adapters, adapter) do
      {:ok, module} when not is_nil(module) ->
        {:ok, module}

      :error ->
        if dispatch_adapter_module?(adapter) do
          {:ok, adapter}
        else
          {:error,
           "#{inspect(adapter)} is not a valid adapter - must be one of :pid, :named, :pubsub, :bus, :logger, :console, :noop, :http, :webhook or a module implementing Jido.Signal.Dispatch.Adapter"}
        end
    end
  end

  defp dispatch_adapter_module?(adapter) when is_atom(adapter) do
    Code.ensure_loaded?(adapter) and
      function_exported?(adapter, :validate_opts, 1) and
      function_exported?(adapter, :deliver, 2) and
      adapter_behaviour?(adapter)
  end

  defp adapter_behaviour?(adapter) do
    behaviours = adapter.module_info(:attributes)[:behaviour] || []
    Jido.Signal.Dispatch.Adapter in behaviours
  rescue
    _ -> false
  end
end
