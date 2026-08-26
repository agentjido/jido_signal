defmodule Jido.Signal.Router do
  @moduledoc """
  Maps Signal type patterns to ordered targets.

  A Router is an immutable indexed lookup value. It supports exact paths, the
  `*` single-segment wildcard, and the `**` multi-segment wildcard. It returns
  matching targets but does not execute them.

  Routes use this precedence:

  1. Exact paths
  2. Paths with `*`
  3. Paths with `**`
  4. Pattern complexity
  5. Higher explicit priority
  6. Earlier registration

  ## Examples

      alias Jido.Signal
      alias Jido.Signal.Router

      router =
        Router.new!([
          {"user.created", :create_user},
          {"user.*", :user_event},
          {"audit.**", :audit}
        ])

      {:ok, [:create_user, :user_event]} =
        Router.route(router, Signal.new!(type: "user.created", source: "/example"))

  A Route can also use a predicate. The predicate runs only after its path
  matches:

      important? = fn signal -> signal.data[:important] == true end
      {:ok, router} = Router.add(router, {"job.completed", important?, :notify})

  Router targets are generic terms. Dispatch target validation belongs to
  `Jido.Signal.Dispatch`.
  """

  alias Jido.Signal
  alias Jido.Signal.Error
  alias Jido.Signal.Router.Index
  alias Jido.Signal.Telemetry

  @type path :: String.t()
  @type match :: (Signal.t() -> boolean())
  @type priority :: -100..100
  @type target :: term()

  @type route_spec ::
          {path(), target()}
          | {path(), target(), priority()}
          | {path(), match(), target()}
          | {path(), match(), target(), priority()}

  defmodule Router do
    @moduledoc false

    @empty_wildcard_index %{
      id: 0,
      exact: %{},
      single: nil,
      multi: nil,
      terminals: [],
      globstar?: false
    }

    @type t :: %__MODULE__{
            entries: [map()],
            exact_index: %{optional(String.t()) => [map()]},
            wildcard_index: map(),
            next_order: non_neg_integer(),
            next_node_id: pos_integer()
          }

    defstruct entries: [],
              exact_index: %{},
              wildcard_index: @empty_wildcard_index,
              next_order: 0,
              next_node_id: 1
  end

  alias __MODULE__.{Route, Router}

  @opaque t :: Router.t()
  @type new_opts :: keyword()

  @doc """
  Normalizes and validates one or more route specifications.

  Accepted forms are `%Route{}`, `{path, target}`, `{path, target, priority}`,
  `{path, match, target}`, and `{path, match, target, priority}`.
  """
  @spec normalize(Route.t() | [Route.t()] | route_spec() | [route_spec()]) ::
          {:ok, [Route.t()]} | {:error, term()}
  def normalize(%Route{} = route) do
    case validate(route) do
      {:ok, validated} -> {:ok, [validated]}
      {:error, _error} = error -> error
    end
  end

  def normalize(routes) when is_list(routes) do
    routes
    |> Enum.reduce_while({:ok, []}, fn input, {:ok, acc} ->
      with {:ok, route} <- normalize_route_spec(input),
           {:ok, route} <- validate(route) do
        {:cont, {:ok, [route | acc]}}
      else
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> reverse_normalized_routes()
  end

  def normalize(route_spec) when is_tuple(route_spec), do: normalize([route_spec])
  def normalize(invalid), do: invalid_route_spec(invalid)

  @doc "Creates a Router from route specifications."
  @spec new(route_spec() | [route_spec()] | [Route.t()] | nil, new_opts()) ::
          {:ok, t()} | {:error, term()}
  def new(routes \\ nil, opts \\ [])

  def new(nil, _opts), do: {:ok, %Router{}}

  def new(routes, _opts) do
    with {:ok, routes} <- normalize(routes) do
      {:ok, Index.new(routes)}
    end
  end

  @doc "Creates a Router and raises for an invalid route specification."
  @spec new!(route_spec() | [route_spec()] | [Route.t()] | nil, new_opts()) :: t()
  def new!(routes \\ nil, opts \\ []) do
    case new(routes, opts) do
      {:ok, router} ->
        router

      {:error, reason} ->
        raise Error.validation_error(
                "Invalid router configuration",
                %{field: "routes", value: routes, reason: reason}
              )
    end
  end

  @doc "Adds one or more routes and preserves their registration order."
  @spec add(t(), route_spec() | Route.t() | [route_spec()] | [Route.t()]) ::
          {:ok, t()} | {:error, term()}
  def add(%Router{} = router, routes) do
    with {:ok, routes} <- normalize(routes) do
      {:ok, Index.add(router, routes)}
    end
  end

  @doc "Removes all routes that have one of the specified paths."
  @spec remove(t(), String.t() | [String.t()]) :: {:ok, t()}
  def remove(%Router{} = router, paths) when is_list(paths) do
    {:ok, Index.remove(router, paths)}
  end

  def remove(%Router{} = router, path) when is_binary(path), do: remove(router, [path])

  @doc "Appends routes or another Router to a Router."
  @spec merge(t(), t() | [Route.t()]) :: {:ok, t()} | {:error, term()}
  def merge(%Router{} = router, %Router{} = other) do
    with {:ok, routes} <- list(other), do: add(router, routes)
  end

  def merge(%Router{} = router, routes) when is_list(routes), do: add(router, routes)
  def merge(%Router{}, invalid), do: {:error, {:invalid_routes, invalid}}

  @doc "Lists Routes in registration order."
  @spec list(t()) :: {:ok, [Route.t()]}
  def list(%Router{} = router), do: {:ok, Enum.map(router.entries, & &1.route)}

  @doc "Returns the number of registered Route values."
  @spec count(t()) :: non_neg_integer()
  def count(%Router{entries: entries}), do: length(entries)

  @doc "Checks if a Router has no routes."
  @spec empty?(t()) :: boolean()
  def empty?(%Router{} = router), do: count(router) == 0

  @doc "Validates one or more Route values with the Route Zoi schema."
  @spec validate(Route.t() | [Route.t()]) ::
          {:ok, Route.t() | [Route.t()]} | {:error, term()}
  def validate(%Route{} = route) do
    case Zoi.parse(Route.schema(), route) do
      {:ok, validated} -> {:ok, validated}
      {:error, errors} -> {:error, route_validation_error(errors, route)}
    end
  end

  def validate(routes) when is_list(routes) do
    routes
    |> Enum.reduce_while({:ok, []}, fn
      %Route{} = route, {:ok, acc} ->
        case validate(route) do
          {:ok, validated} -> {:cont, {:ok, [validated | acc]}}
          {:error, _error} = error -> {:halt, error}
        end

      invalid, {:ok, _acc} ->
        {:halt,
         {:error,
          Error.validation_error("Expected Route struct", %{
            field: "route",
            value: invalid
          })}}
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      {:error, _error} = error -> error
    end
  end

  def validate(invalid) do
    {:error,
     Error.validation_error(
       "Expected Route struct or list of Route structs",
       %{field: "routes", value: invalid}
     )}
  end

  @doc """
  Returns all targets whose route path and optional `Route.match` predicate
  match a Signal.

  Returns the existing structured routing error when no target matches.
  """
  @spec route(t(), Signal.t()) :: {:ok, [term()]} | {:error, term()}
  def route(%Router{}, %Signal{type: nil}) do
    {:error,
     Error.routing_error(
       "Signal type cannot be nil",
       %{route: nil, reason: :nil_signal_type}
     )}
  end

  def route(%Router{} = router, %Signal{type: type} = signal) when is_binary(type) do
    start_time = System.monotonic_time(:microsecond)
    targets = Index.lookup(router, type, signal)
    emit_route_telemetry(signal, targets, start_time)

    case targets do
      [] -> no_match(signal)
      targets -> {:ok, targets}
    end
  end

  def route(%Router{}, %Signal{} = signal) do
    {:error,
     Error.routing_error(
       "Signal type must be a string",
       %{route: signal.type, reason: :invalid_signal_type}
     )}
  end

  @doc "Checks if a Signal type matches a route path pattern."
  @spec matches?(String.t() | term(), String.t() | term()) :: boolean()
  def matches?(type, pattern) when is_binary(type) and is_binary(pattern) do
    case Route.validate_path(pattern, []) do
      :ok -> Index.matches?(type, pattern)
      {:error, _reason} -> false
    end
  end

  def matches?(_type, _pattern), do: false

  @doc "Filters Signals whose types match a route path pattern."
  @spec filter([Signal.t()] | term(), String.t() | term()) :: [Signal.t()]
  def filter(signals, pattern) when is_list(signals) and is_binary(pattern) do
    case Route.validate_path(pattern, []) do
      :ok ->
        Enum.filter(signals, fn
          %Signal{type: type} when is_binary(type) -> Index.matches?(type, pattern)
          _signal -> false
        end)

      {:error, _reason} ->
        []
    end
  end

  def filter(_signals, _pattern), do: []

  @doc "Checks if an exact route path is registered."
  @spec has_route?(t(), String.t()) :: boolean()
  def has_route?(%Router{} = router, path) when is_binary(path) do
    case Route.validate_path(path, []) do
      :ok -> Index.has_route?(router, path)
      {:error, _reason} -> false
    end
  end

  def has_route?(_router, _path), do: false

  defp normalize_route_spec(%Route{} = route), do: {:ok, route}

  defp normalize_route_spec({path, target}) when is_binary(path),
    do: {:ok, %Route{path: path, target: target}}

  defp normalize_route_spec({path, target, priority})
       when is_binary(path) and is_integer(priority),
       do: {:ok, %Route{path: path, target: target, priority: priority}}

  defp normalize_route_spec({path, match, target})
       when is_binary(path) and is_function(match, 1),
       do: {:ok, %Route{path: path, match: match, target: target}}

  defp normalize_route_spec({path, match, target, priority})
       when is_binary(path) and is_function(match, 1) and is_integer(priority),
       do: {:ok, %Route{path: path, match: match, target: target, priority: priority}}

  defp normalize_route_spec(invalid), do: invalid_route_spec(invalid)

  defp invalid_route_spec(invalid) do
    {:error,
     Error.validation_error(
       "Invalid route specification format",
       %{
         value: invalid,
         expected_formats: [
           "%Route{}",
           "{path, target}",
           "{path, target, priority}",
           "{path, match_fn, target}",
           "{path, match_fn, target, priority}"
         ]
       }
     )}
  end

  defp reverse_normalized_routes({:ok, routes}), do: {:ok, Enum.reverse(routes)}
  defp reverse_normalized_routes({:error, _error} = error), do: error

  defp route_validation_error([%{message: message} | _errors], route) do
    Error.routing_error(message, %{route: route.path})
  end

  defp route_validation_error(_errors, route) do
    Error.routing_error("Invalid route", %{route: route.path})
  end

  defp emit_route_telemetry(signal, targets, start_time) do
    Telemetry.execute(
      [:jido, :signal, :router, :routed],
      %{
        latency_us: System.monotonic_time(:microsecond) - start_time,
        match_count: length(targets)
      },
      %{signal_type: signal.type, matched: targets != []},
      signal
    )
  end

  defp no_match(signal) do
    {:error,
     Error.routing_error(
       "No matching handlers found for signal",
       %{signal_type: signal.type, route: signal.type, reason: :no_handlers_found}
     )}
  end
end
