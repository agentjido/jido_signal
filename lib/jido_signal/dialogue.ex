defmodule Jido.Signal.Dialogue do
  @moduledoc """
  Provides an in-memory, immutable Dialogue data structure that models a conversation
  as a directed acyclic graph of Jido Signal structs.

  A Dialogue represents hierarchical conversations (like Slack threads) where signals
  can be organized in a tree structure with a maximum depth of 5 levels.

  ## Features

  - **Immutable**: Every mutating operation returns a new Dialogue
  - **DAG Structure**: Uses libgraph for efficient graph operations
  - **Out-of-order Support**: Signals can be added in any order via parent_id references
  - **Depth Limiting**: Enforces maximum 5 levels of nesting
  - **Orphan Handling**: Temporary storage for signals awaiting their parent

  ## Structure

  - `graph`: libgraph structure with signal IDs as nodes and parent→child edges
  - `signals`: Fast lookup map from signal ID to signal struct
  - `orphans`: Set of signal IDs waiting for missing parents
  - `max_depth`: Constant value of 5

  ## Usage

      # Create with trigger signal
      trigger = %Jido.Signal{id: "uuid1", type: "conversation.started", source: "/chat"}
      dialogue = Jido.Signal.Dialogue.new(trigger)

      # Add child signals
      child = %Jido.Signal{id: "uuid2", type: "message.sent", source: "/chat", data: %{parent_id: "uuid1"}}
      {:ok, dialogue} = Jido.Signal.Dialogue.add_signal(dialogue, child)

      # Query structure
      children = Jido.Signal.Dialogue.children_of(dialogue, "uuid1")
      threads = Jido.Signal.Dialogue.to_threaded_list(dialogue)
  """

  use TypedStruct
  alias Graph

  @max_depth 5

  typedstruct do
    field(:graph, Graph.t(), default: Graph.new())
    field(:signals, %{String.t() => Jido.Signal.t()}, default: %{})
    field(:orphans, MapSet.t(String.t()), default: MapSet.new())
    field(:max_depth, pos_integer(), default: @max_depth)
  end

  @doc """
  Creates a new Dialogue with the given trigger signal.

  The trigger signal serves as the root of the conversation and must not have a parent_id.

  ## Parameters

  - `trigger`: A Jido.Signal struct that will be the root of the dialogue

  ## Returns

  A new Dialogue struct with the trigger signal as the root node.

  ## Examples

      iex> trigger = %Jido.Signal{id: "root", type: "conversation.started", source: "/chat"}
      iex> dialogue = Jido.Signal.Dialogue.new(trigger)
      iex> Map.has_key?(dialogue.signals, "root")
      true
  """
  @spec new(Jido.Signal.t()) :: t()
  def new(%Jido.Signal{} = trigger) do
    %__MODULE__{
      graph: Graph.add_vertex(Graph.new(), trigger.id),
      signals: %{trigger.id => trigger}
    }
  end

  @doc """
  Creates a Dialogue from a list of signals.

  Signals are processed in order, with orphans resolved as their parents become available.
  If any orphans remain unresolved, an error is returned.

  ## Parameters

  - `signals`: List of Jido.Signal structs, first should be the trigger (no parent_id)

  ## Returns

  `{:ok, dialogue}` if all signals can be organized, `{:error, reason}` otherwise.

  ## Examples

      iex> signals = [
      ...>   %Jido.Signal{id: "1", type: "trigger", source: "/chat"},
      ...>   %Jido.Signal{id: "2", type: "reply", source: "/chat", data: %{parent_id: "1"}}
      ...> ]
      iex> {:ok, dialogue} = Jido.Signal.Dialogue.from_signals(signals)
      iex> length(Map.keys(dialogue.signals))
      2
  """
  @spec from_signals([Jido.Signal.t()]) :: {:ok, t()} | {:error, term()}
  def from_signals([]) do
    {:error, :empty_signal_list}
  end

  def from_signals(signals) when is_list(signals) do
    # Find the root signal (one with no parent_id)
    {roots, non_roots} =
      Enum.split_with(signals, fn signal ->
        get_parent_id(signal) == nil
      end)

    case roots do
      [] ->
        {:error, :no_root_signal}

      [root | extra_roots] ->
        # Start with the first root signal
        dialogue = new(root)

        # Add any extra roots as separate root signals
        dialogue_with_roots =
          Enum.reduce(extra_roots, dialogue, fn root_signal, acc ->
            # Add as vertex without parent edge
            graph = Graph.add_vertex(acc.graph, root_signal.id)
            signals = Map.put(acc.signals, root_signal.id, root_signal)
            %{acc | graph: graph, signals: signals}
          end)

        # Now add all non-root signals
        result =
          Enum.reduce_while(non_roots, dialogue_with_roots, fn signal, acc ->
            case add_signal(acc, signal) do
              {:ok, new_dialogue} -> {:cont, new_dialogue}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)

        case result do
          {:error, reason} ->
            {:error, reason}

          dialogue ->
            if MapSet.size(dialogue.orphans) > 0 do
              {:error, {:orphans, MapSet.to_list(dialogue.orphans)}}
            else
              {:ok, dialogue}
            end
        end
    end
  end

  @doc """
  Adds a signal to the dialogue.

  The signal is placed in the graph based on its parent_id (found in data field).
  If the parent doesn't exist yet, the signal is added to orphans.
  After adding, attempts to resolve any orphans that can now be placed.

  ## Parameters

  - `dialogue`: The current dialogue
  - `signal`: The signal to add

  ## Returns

  `{:ok, new_dialogue}` on success, `{:error, reason}` on failure.

  ## Error Conditions

  - `:duplicate` - Signal ID already exists
  - `:depth_exceeded` - Adding would exceed max_depth of 5
  - `:unknown_parent` - Parent ID not found (only in strict mode)

  ## Examples

      iex> dialogue = Jido.Signal.Dialogue.new(%Jido.Signal{id: "1", type: "trigger", source: "/chat"})
      iex> child = %Jido.Signal{id: "2", type: "reply", source: "/chat", data: %{parent_id: "1"}}
      iex> {:ok, updated} = Jido.Signal.Dialogue.add_signal(dialogue, child)
      iex> length(Jido.Signal.Dialogue.children_of(updated, "1"))
      1
  """
  @spec add_signal(t(), Jido.Signal.t()) ::
          {:ok, t()} | {:error, :duplicate | :unknown_parent | :depth_exceeded}
  def add_signal(%__MODULE__{} = dialogue, %Jido.Signal{} = signal) do
    cond do
      Map.has_key?(dialogue.signals, signal.id) ->
        {:error, :duplicate}

      true ->
        parent_id = get_parent_id(signal)

        cond do
          is_nil(parent_id) ->
            # This is a root signal, add it directly
            add_signal_to_graph(dialogue, signal, nil)

          Map.has_key?(dialogue.signals, parent_id) ->
            # Parent exists, check depth and add
            parent_depth = depth_of(dialogue, parent_id)

            if parent_depth + 1 > @max_depth do
              {:error, :depth_exceeded}
            else
              add_signal_to_graph(dialogue, signal, parent_id)
            end

          true ->
            # Parent doesn't exist, add to orphans
            add_to_orphans(dialogue, signal)
        end
    end
  end

  @doc """
  Returns the direct children of a given signal.

  Children are returned sorted by their timestamp (earliest first).

  ## Parameters

  - `dialogue`: The dialogue to query
  - `signal_id`: The ID of the parent signal

  ## Returns

  List of Jido.Signal structs that are direct children of the given signal.

  ## Examples

      iex> signals = [
      ...>   %Jido.Signal{id: "parent", type: "trigger", source: "/chat"},
      ...>   %Jido.Signal{id: "child1", type: "reply", source: "/chat", data: %{parent_id: "parent"}},
      ...>   %Jido.Signal{id: "child2", type: "reply", source: "/chat", data: %{parent_id: "parent"}}
      ...> ]
      iex> {:ok, dialogue} = Jido.Signal.Dialogue.from_signals(signals)
      iex> children = Jido.Signal.Dialogue.children_of(dialogue, "parent")
      iex> length(children)
      2
  """
  @spec children_of(t(), String.t()) :: [Jido.Signal.t()]
  def children_of(%__MODULE__{} = dialogue, signal_id) do
    case Graph.out_neighbors(dialogue.graph, signal_id) do
      [] ->
        []

      child_ids ->
        child_ids
        |> Enum.map(&Map.get(dialogue.signals, &1))
        |> Enum.filter(& &1)
        |> Enum.sort_by(&get_timestamp/1)
    end
  end

  @doc """
  Returns all ancestors of a signal in root-first order.

  ## Parameters

  - `dialogue`: The dialogue to query
  - `signal_id`: The ID of the signal

  ## Returns

  List of ancestor signals from root to immediate parent.

  ## Examples

      iex> signals = [
      ...>   %Jido.Signal{id: "root", type: "trigger", source: "/chat"},
      ...>   %Jido.Signal{id: "child", type: "reply", source: "/chat", data: %{parent_id: "root"}},
      ...>   %Jido.Signal{id: "leaf", type: "reply", source: "/chat", data: %{parent_id: "child"}}
      ...> ]
      iex> {:ok, dialogue} = Jido.Signal.Dialogue.from_signals(signals)
      iex> ancestors = Jido.Signal.Dialogue.ancestors_of(dialogue, "leaf")
      iex> List.first(ancestors).id
      "root"
  """
  @spec ancestors_of(t(), String.t()) :: [Jido.Signal.t()]
  def ancestors_of(%__MODULE__{} = dialogue, signal_id) do
    case Graph.reaching_neighbors(dialogue.graph, [signal_id]) do
      [] ->
        []

      ancestor_ids ->
        # Remove the signal itself and convert to structs
        ancestor_ids
        |> List.delete(signal_id)
        |> Enum.map(&Map.get(dialogue.signals, &1))
        |> Enum.filter(& &1)
        |> sort_ancestors_root_first(dialogue)
    end
  end

  @doc """
  Returns the depth of a signal in the dialogue tree.

  Root signals have depth 0, their children depth 1, etc.

  ## Parameters

  - `dialogue`: The dialogue to query
  - `signal_id`: The ID of the signal

  ## Returns

  Non-negative integer representing the depth, or 0 if signal not found.

  ## Examples

      iex> signals = [
      ...>   %Jido.Signal{id: "root", type: "trigger", source: "/chat"},
      ...>   %Jido.Signal{id: "child", type: "reply", source: "/chat", data: %{parent_id: "root"}}
      ...> ]
      iex> {:ok, dialogue} = Jido.Signal.Dialogue.from_signals(signals)
      iex> Jido.Signal.Dialogue.depth_of(dialogue, "root")
      0
      iex> Jido.Signal.Dialogue.depth_of(dialogue, "child")
      1
  """
  @spec depth_of(t(), String.t()) :: non_neg_integer()
  def depth_of(%__MODULE__{} = dialogue, signal_id) do
    length(ancestors_of(dialogue, signal_id))
  end

  @doc """
  Converts the dialogue to a threaded list format suitable for chat UIs.

  Returns a list of lists, where each sublist represents a conversation thread
  from root to leaf, ordered by timestamp.

  ## Parameters

  - `dialogue`: The dialogue to convert

  ## Returns

  List of lists of Jido.Signal structs, each representing a conversation thread.

  ## Examples

      iex> signals = [
      ...>   %Jido.Signal{id: "root", type: "trigger", source: "/chat"},
      ...>   %Jido.Signal{id: "child1", type: "reply", source: "/chat", data: %{parent_id: "root"}},
      ...>   %Jido.Signal{id: "child2", type: "reply", source: "/chat", data: %{parent_id: "root"}},
      ...>   %Jido.Signal{id: "grandchild", type: "reply", source: "/chat", data: %{parent_id: "child1"}}
      ...> ]
      iex> {:ok, dialogue} = Jido.Signal.Dialogue.from_signals(signals)
      iex> threads = Jido.Signal.Dialogue.to_threaded_list(dialogue)
      iex> length(threads)
      2
  """
  @spec to_threaded_list(t()) :: [[Jido.Signal.t()]]
  def to_threaded_list(%__MODULE__{} = dialogue) do
    # Find all root signals (nodes with no incoming edges)
    roots = find_root_signals(dialogue)

    # For each root, build all paths to leaves
    Enum.flat_map(roots, fn root_id ->
      build_paths_from_root(dialogue, root_id)
    end)
  end

  # Private helper functions

  defp get_parent_id(%Jido.Signal{data: %{parent_id: parent_id}}) when is_binary(parent_id),
    do: parent_id

  defp get_parent_id(%Jido.Signal{data: data}) when is_map(data),
    do: Map.get(data, "parent_id")

  defp get_parent_id(_signal), do: nil

  defp get_timestamp(%Jido.Signal{time: time}) when is_binary(time) do
    case DateTime.from_iso8601(time) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp get_timestamp(_signal), do: DateTime.utc_now()

  defp add_signal_to_graph(dialogue, signal, parent_id) do
    # Add vertex for signal
    graph = Graph.add_vertex(dialogue.graph, signal.id)

    # Add edge if parent exists
    graph =
      if parent_id do
        Graph.add_edge(graph, parent_id, signal.id)
      else
        graph
      end

    # Update signals map
    signals = Map.put(dialogue.signals, signal.id, signal)

    # Create updated dialogue
    updated_dialogue = %{dialogue | graph: graph, signals: signals}

    # Try to resolve orphans
    resolve_orphans(updated_dialogue)
  end

  defp add_to_orphans(dialogue, signal) do
    orphans = MapSet.put(dialogue.orphans, signal.id)
    signals = Map.put(dialogue.signals, signal.id, signal)

    {:ok, %{dialogue | orphans: orphans, signals: signals}}
  end

  defp resolve_orphans(dialogue) do
    {resolved_orphans, remaining_orphans} =
      dialogue.orphans
      |> MapSet.to_list()
      |> Enum.split_with(fn orphan_id ->
        signal = Map.get(dialogue.signals, orphan_id)
        parent_id = get_parent_id(signal)
        parent_id && Map.has_key?(dialogue.signals, parent_id)
      end)

    # Process resolved orphans
    final_dialogue =
      Enum.reduce(resolved_orphans, dialogue, fn orphan_id, acc ->
        signal = Map.get(acc.signals, orphan_id)
        parent_id = get_parent_id(signal)

        # Check depth constraint
        parent_depth = depth_of(acc, parent_id)

        if parent_depth + 1 <= @max_depth do
          # Add edge to graph
          graph = Graph.add_edge(acc.graph, parent_id, signal.id)
          %{acc | graph: graph}
        else
          # Remove from signals if depth exceeded
          signals = Map.delete(acc.signals, orphan_id)
          %{acc | signals: signals}
        end
      end)

    # Update orphans set
    final_dialogue = %{
      final_dialogue
      | orphans: MapSet.new(remaining_orphans)
    }

    # Recursively resolve if we made progress
    if length(resolved_orphans) > 0 and MapSet.size(final_dialogue.orphans) > 0 do
      resolve_orphans(final_dialogue)
    else
      {:ok, final_dialogue}
    end
  end

  defp sort_ancestors_root_first(ancestors, dialogue) do
    # Sort by depth (ascending) to get root-first order
    Enum.sort_by(ancestors, fn ancestor ->
      depth_of(dialogue, ancestor.id)
    end)
  end

  defp find_root_signals(dialogue) do
    Graph.vertices(dialogue.graph)
    |> Enum.filter(fn vertex_id ->
      Graph.in_degree(dialogue.graph, vertex_id) == 0
    end)
  end

  defp build_paths_from_root(dialogue, root_id) do
    case children_of(dialogue, root_id) do
      [] ->
        # Leaf node, return single-element path
        [[Map.get(dialogue.signals, root_id)]]

      children ->
        # Recursively build paths for each child
        Enum.flat_map(children, fn child ->
          child_paths = build_paths_from_root(dialogue, child.id)

          Enum.map(child_paths, fn path ->
            [Map.get(dialogue.signals, root_id) | path]
          end)
        end)
    end
  end
end
