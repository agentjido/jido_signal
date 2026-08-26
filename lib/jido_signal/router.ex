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

  defmodule Route do
    @moduledoc """
    A validated Signal routing rule.

    `path` selects Signal types. `target` is any value returned by the Router.
    `priority` orders routes with equal path specificity. An optional `match`
    predicate can inspect the full Signal after the path matches.
    """

    alias Jido.Signal

    @schema Zoi.struct(
              __MODULE__,
              %{
                path:
                  Zoi.any()
                  |> Zoi.refine({__MODULE__, :validate_path, []}),
                target: Zoi.any(),
                priority:
                  Zoi.any()
                  |> Zoi.refine({__MODULE__, :validate_priority, []})
                  |> Zoi.default(0)
                  |> Zoi.optional(),
                match:
                  Zoi.any()
                  |> Zoi.refine({__MODULE__, :validate_match, []})
                  |> Zoi.nullable()
                  |> Zoi.optional()
              }
            )

    @type t :: %__MODULE__{
            path: String.t(),
            target: term(),
            priority: -100..100,
            match: nil | (Signal.t() -> boolean())
          }

    @enforce_keys Zoi.Struct.enforce_keys(@schema)
    defstruct Zoi.Struct.struct_fields(@schema)

    @doc "Returns the Zoi schema for a Route."
    @spec schema() :: Zoi.schema()
    def schema, do: @schema

    @doc false
    def validate_path(path, _opts) when not is_binary(path),
      do: {:error, "Path must be a string"}

    def validate_path(path, _opts) do
      segments = String.split(path, ".")

      cond do
        String.contains?(path, "..") ->
          {:error, "Path cannot contain consecutive dots"}

        consecutive_multi_wildcards?(segments) ->
          {:error, "Path cannot contain multiple wildcards"}

        invalid = Enum.find(segments, &(not valid_segment?(&1))) ->
          invalid_segment_error(invalid)

        true ->
          :ok
      end
    end

    @doc false
    def validate_priority(nil, _opts), do: :ok

    def validate_priority(priority, _opts) when is_integer(priority) and priority > 100,
      do: {:error, "Priority value exceeds maximum allowed"}

    def validate_priority(priority, _opts) when is_integer(priority) and priority < -100,
      do: {:error, "Priority value below minimum allowed"}

    def validate_priority(priority, _opts) when is_integer(priority), do: :ok
    def validate_priority(_priority, _opts), do: {:error, "Priority must be an integer"}

    @doc false
    def validate_match(nil, _opts), do: :ok
    def validate_match(match, _opts) when is_function(match, 1), do: :ok

    def validate_match(_match, _opts),
      do: {:error, "Match must be a function that takes one argument"}

    defp consecutive_multi_wildcards?(segments) do
      segments
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.any?(fn [left, right] -> left == "**" and right == "**" end)
    end

    defp valid_segment?("*"), do: true
    defp valid_segment?("**"), do: true
    defp valid_segment?(segment), do: String.match?(segment, ~r/^[a-zA-Z0-9_-]+$/)

    defp invalid_segment_error(segment) do
      cond do
        String.contains?(segment, "**") ->
          {:error, "Path cannot contain '**' sequence"}

        String.contains?(segment, "*") ->
          {:error, "Path cannot contain '*' within a segment"}

        true ->
          {:error, "Path contains invalid characters"}
      end
    end
  end

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
      {entries, next_order} = compile_entries(routes, 0)
      empty = %Router{}

      {exact_index, wildcard_index, next_node_id} =
        index_entries(
          entries,
          empty.exact_index,
          empty.wildcard_index,
          empty.next_node_id
        )

      {:ok,
       %Router{
         entries: entries,
         exact_index: exact_index,
         wildcard_index: wildcard_index,
         next_order: next_order,
         next_node_id: next_node_id
       }}
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
      {new_entries, next_order} = compile_entries(routes, router.next_order)
      entries = router.entries ++ new_entries

      {exact_index, wildcard_index, next_node_id} =
        index_entries(
          new_entries,
          router.exact_index,
          router.wildcard_index,
          router.next_node_id
        )

      {:ok,
       %{
         router
         | entries: entries,
           exact_index: exact_index,
           wildcard_index: wildcard_index,
           next_order: next_order,
           next_node_id: next_node_id
       }}
    end
  end

  @doc "Removes all routes that have one of the specified paths."
  @spec remove(t(), String.t() | [String.t()]) :: {:ok, t()}
  def remove(%Router{} = router, paths) when is_list(paths) do
    paths = MapSet.new(paths)
    entries = Enum.reject(router.entries, &MapSet.member?(paths, &1.route.path))

    {exact_index, wildcard_index} =
      Enum.reduce(paths, {router.exact_index, router.wildcard_index}, fn path,
                                                                         {exact, wildcard} ->
        if wildcard_path?(path) do
          {exact, delete_trie_path(wildcard, String.split(path, "."))}
        else
          {Map.delete(exact, path), wildcard}
        end
      end)

    {:ok, %{router | entries: entries, exact_index: exact_index, wildcard_index: wildcard_index}}
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
    type_segments = String.split(type, ".")

    targets =
      (Map.get(router.exact_index, type, []) ++
         wildcard_matches(router.wildcard_index, type_segments))
      |> Enum.filter(&predicate_matches?(&1.route.match, signal))
      |> Enum.sort_by(&precedence_key/1, :desc)
      |> Enum.flat_map(&targets/1)

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
      :ok -> match_segments?(String.split(type, "."), String.split(pattern, "."))
      {:error, _reason} -> false
    end
  end

  def matches?(_type, _pattern), do: false

  @doc "Filters Signals whose types match a route path pattern."
  @spec filter([Signal.t()] | term(), String.t() | term()) :: [Signal.t()]
  def filter(signals, pattern) when is_list(signals) and is_binary(pattern) do
    case Route.validate_path(pattern, []) do
      :ok ->
        pattern_segments = String.split(pattern, ".")

        Enum.filter(signals, fn
          %Signal{type: type} when is_binary(type) ->
            match_segments?(String.split(type, "."), pattern_segments)

          _signal ->
            false
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
      :ok ->
        if wildcard_path?(path) do
          trie_has_path?(router.wildcard_index, String.split(path, "."))
        else
          Map.has_key?(router.exact_index, path)
        end

      {:error, _reason} ->
        false
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

  defp compile_entries(routes, first_order) do
    Enum.map_reduce(routes, first_order, fn route, order ->
      segments = String.split(route.path, ".")

      entry = %{
        route: route,
        segments: segments,
        class: pattern_class(segments),
        complexity: pattern_complexity(segments),
        order: order
      }

      {entry, order + 1}
    end)
  end

  defp index_entries(entries, exact_index, wildcard_index, next_node_id) do
    Enum.reduce(
      entries,
      {exact_index, wildcard_index, next_node_id},
      fn entry, {exact, wildcard, node_id} ->
        if entry.class == 2 do
          exact = Map.update(exact, entry.route.path, [entry], &[entry | &1])
          {exact, wildcard, node_id}
        else
          {wildcard, node_id} = insert_trie(wildcard, entry.segments, entry, node_id)
          {exact, wildcard, node_id}
        end
      end
    )
  end

  defp insert_trie(node, [], entry, next_node_id) do
    {%{node | terminals: [entry | node.terminals]}, next_node_id}
  end

  defp insert_trie(node, [segment | rest], entry, next_node_id) do
    {child, next_node_id} = trie_child(node, segment, next_node_id)
    {child, next_node_id} = insert_trie(child, rest, entry, next_node_id)
    {put_trie_child(node, segment, child), next_node_id}
  end

  defp trie_child(node, "*", next_node_id),
    do: existing_or_new_node(node.single, next_node_id, false)

  defp trie_child(node, "**", next_node_id),
    do: existing_or_new_node(node.multi, next_node_id, true)

  defp trie_child(node, segment, next_node_id),
    do: existing_or_new_node(Map.get(node.exact, segment), next_node_id, false)

  defp existing_or_new_node(nil, next_node_id, globstar?) do
    {new_trie_node(next_node_id, globstar?), next_node_id + 1}
  end

  defp existing_or_new_node(node, next_node_id, _globstar?), do: {node, next_node_id}

  defp new_trie_node(id, globstar?) do
    %{
      id: id,
      exact: %{},
      single: nil,
      multi: nil,
      terminals: [],
      globstar?: globstar?
    }
  end

  defp put_trie_child(node, "*", child), do: %{node | single: child}
  defp put_trie_child(node, "**", child), do: %{node | multi: child}

  defp put_trie_child(node, segment, child) do
    %{node | exact: Map.put(node.exact, segment, child)}
  end

  defp wildcard_matches(
         %{exact: exact, single: nil, multi: nil, terminals: []},
         _segments
       )
       when map_size(exact) == 0,
       do: []

  defp wildcard_matches(root, segments) do
    segments = List.to_tuple(segments)
    {_visited, matches} = walk_trie(root, segments, tuple_size(segments), 0, MapSet.new(), [])
    matches
  end

  defp walk_trie(node, segments, segment_count, position, visited, matches) do
    state = {node.id, position}

    if MapSet.member?(visited, state) do
      {visited, matches}
    else
      visited = MapSet.put(visited, state)

      matches =
        if position == segment_count do
          node.terminals ++ matches
        else
          matches
        end

      {visited, matches} =
        walk_segment_children(node, segments, segment_count, position, visited, matches)

      {visited, matches} =
        case node.multi do
          nil -> {visited, matches}
          child -> walk_trie(child, segments, segment_count, position, visited, matches)
        end

      if node.globstar? and position < segment_count do
        walk_trie(node, segments, segment_count, position + 1, visited, matches)
      else
        {visited, matches}
      end
    end
  end

  defp walk_segment_children(node, segments, segment_count, position, visited, matches)
       when position < segment_count do
    segment = elem(segments, position)

    {visited, matches} =
      case Map.get(node.exact, segment) do
        nil -> {visited, matches}
        child -> walk_trie(child, segments, segment_count, position + 1, visited, matches)
      end

    case node.single do
      nil -> {visited, matches}
      child -> walk_trie(child, segments, segment_count, position + 1, visited, matches)
    end
  end

  defp walk_segment_children(
         _node,
         _segments,
         _segment_count,
         _position,
         visited,
         matches
       ),
       do: {visited, matches}

  defp delete_trie_path(node, []), do: %{node | terminals: []}

  defp delete_trie_path(node, [segment | rest]) do
    case get_trie_child(node, segment) do
      nil ->
        node

      child ->
        child = delete_trie_path(child, rest)
        put_or_delete_trie_child(node, segment, child)
    end
  end

  defp get_trie_child(node, "*"), do: node.single
  defp get_trie_child(node, "**"), do: node.multi
  defp get_trie_child(node, segment), do: Map.get(node.exact, segment)

  defp put_or_delete_trie_child(node, segment, child) do
    if empty_trie_node?(child) do
      delete_trie_child(node, segment)
    else
      put_trie_child(node, segment, child)
    end
  end

  defp delete_trie_child(node, "*"), do: %{node | single: nil}
  defp delete_trie_child(node, "**"), do: %{node | multi: nil}
  defp delete_trie_child(node, segment), do: %{node | exact: Map.delete(node.exact, segment)}

  defp empty_trie_node?(node) do
    node.terminals == [] and node.single == nil and node.multi == nil and
      map_size(node.exact) == 0
  end

  defp trie_has_path?(node, []), do: node.terminals != []

  defp trie_has_path?(node, [segment | rest]) do
    case get_trie_child(node, segment) do
      nil -> false
      child -> trie_has_path?(child, rest)
    end
  end

  defp wildcard_path?(path), do: String.contains?(path, "*")

  defp pattern_class(segments) do
    cond do
      "**" in segments -> 0
      "*" in segments -> 1
      true -> 2
    end
  end

  # Preserve the v2 complexity order inside each wildcard class.
  defp pattern_complexity(segments) do
    length = length(segments)
    base_score = length * 2000

    exact_score =
      segments
      |> Enum.with_index()
      |> Enum.reduce(0, fn
        {segment, _index}, score when segment in ["*", "**"] -> score
        {_segment, index}, score -> score + 3000 * (length - index)
      end)

    wildcard_penalty =
      segments
      |> Enum.with_index()
      |> Enum.reduce(0, fn
        {"*", index}, score -> score + 1000 - index * 100
        {"**", index}, score -> score + 2000 - index * 200
        {_segment, _index}, score -> score
      end)

    base_score + exact_score - wildcard_penalty
  end

  defp precedence_key(entry) do
    {entry.class, entry.complexity, entry.route.priority, -entry.order}
  end

  defp predicate_matches?(nil, _signal), do: true

  defp predicate_matches?(match, signal) do
    match.(signal) == true
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp targets(%{route: %Route{target: targets}}) when is_list(targets), do: targets
  defp targets(%{route: %Route{target: target}}), do: [target]

  defp match_segments?(type_segments, pattern_segments) do
    type_segments = List.to_tuple(type_segments)
    pattern_segments = List.to_tuple(pattern_segments)

    do_match_segments(
      type_segments,
      pattern_segments,
      tuple_size(type_segments),
      tuple_size(pattern_segments),
      0,
      0,
      nil,
      nil
    )
  end

  defp do_match_segments(type, pattern, type_size, pattern_size, i, j, star_i, star_j) do
    cond do
      i < type_size and j < pattern_size and
          segment_matches?(elem(type, i), elem(pattern, j)) ->
        do_match_segments(type, pattern, type_size, pattern_size, i + 1, j + 1, star_i, star_j)

      j < pattern_size and elem(pattern, j) == "**" ->
        do_match_segments(type, pattern, type_size, pattern_size, i, j + 1, i, j + 1)

      i == type_size ->
        remaining_multi_wildcards?(pattern, j, pattern_size)

      not is_nil(star_j) and star_i < type_size ->
        next_i = star_i + 1
        do_match_segments(type, pattern, type_size, pattern_size, next_i, star_j, next_i, star_j)

      true ->
        false
    end
  end

  defp segment_matches?(type_segment, pattern_segment),
    do: pattern_segment == "*" or pattern_segment == type_segment

  defp remaining_multi_wildcards?(_pattern, index, size) when index == size, do: true

  defp remaining_multi_wildcards?(pattern, index, size) do
    elem(pattern, index) == "**" and remaining_multi_wildcards?(pattern, index + 1, size)
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
