defmodule Jido.Signal.DialoguePropertyTest do
  use ExUnit.Case
  use ExUnitProperties
  alias Jido.Signal.Dialogue
  alias Jido.Signal

  # Property-based tests to ensure dialogue behavior is correct
  # regardless of signal insertion order

  property "insertion order doesn't affect final threaded view for simple cases" do
    check all(
            root_id <- string(:alphanumeric, min_length: 1, max_length: 10),
            child_count <- integer(1..3)
          ) do
      # Create signals with root and children (using unique IDs)
      root = %Signal{id: root_id, type: "trigger", source: "/test"}

      children =
        1..child_count
        |> Enum.map(fn i ->
          %Signal{
            id: "#{root_id}_child_#{i}",
            type: "message",
            source: "/test",
            data: %{parent_id: root_id},
            time: DateTime.utc_now() |> DateTime.to_iso8601()
          }
        end)

      signals = [root | children]

      # Create dialogue from signals in original order
      {:ok, dialogue1} = Dialogue.from_signals(signals)
      threads1 = Dialogue.to_threaded_list(dialogue1)

      # Create dialogue from shuffled signals
      shuffled_signals = Enum.shuffle(signals)
      {:ok, dialogue2} = Dialogue.from_signals(shuffled_signals)
      threads2 = Dialogue.to_threaded_list(dialogue2)

      # Both should have same number of threads
      assert length(threads1) == length(threads2)
      assert length(threads1) == child_count

      # Each thread should start with root and have length 2
      Enum.each(threads1, fn thread ->
        assert length(thread) == 2
        assert List.first(thread).id == root_id
      end)

      Enum.each(threads2, fn thread ->
        assert length(thread) == 2
        assert List.first(thread).id == root_id
      end)

      # Normalize threads for comparison (sort by second element ID)
      normalized_threads1 =
        threads1
        |> Enum.map(fn [root, child] -> [root.id, child.id] end)
        |> Enum.sort()

      normalized_threads2 =
        threads2
        |> Enum.map(fn [root, child] -> [root.id, child.id] end)
        |> Enum.sort()

      assert normalized_threads1 == normalized_threads2
    end
  end

  property "adding signals incrementally produces same result as bulk creation for simple trees" do
    check all(
            root_id <- string(:alphanumeric, min_length: 1, max_length: 10),
            child_count <- integer(1..3)
          ) do
      # Create simple signals: root + children
      root = %Signal{id: root_id, type: "trigger", source: "/test"}

      children =
        1..child_count
        |> Enum.map(fn i ->
          %Signal{
            id: "child#{i}",
            type: "message",
            source: "/test",
            data: %{parent_id: root_id}
          }
        end)

      signals = [root | children]

      # Create via from_signals
      {:ok, bulk_dialogue} = Dialogue.from_signals(signals)

      # Create incrementally
      incremental_dialogue =
        Enum.reduce(children, Dialogue.new(root), fn signal, acc ->
          {:ok, updated} = Dialogue.add_signal(acc, signal)
          updated
        end)

      # Both should have same structure
      assert map_size(bulk_dialogue.signals) == map_size(incremental_dialogue.signals)
      assert MapSet.size(bulk_dialogue.orphans) == MapSet.size(incremental_dialogue.orphans)

      # All children should be children of root in both
      bulk_children = Dialogue.children_of(bulk_dialogue, root_id)
      incremental_children = Dialogue.children_of(incremental_dialogue, root_id)

      assert length(bulk_children) == length(incremental_children)
      assert length(bulk_children) == child_count
    end
  end

  property "depth is always computed correctly for linear chains" do
    check all(chain_length <- integer(1..5)) do
      # Create a linear chain of signals
      signals =
        1..chain_length
        |> Enum.map(fn i ->
          parent_id = if i == 1, do: nil, else: "signal#{i - 1}"

          %Signal{
            id: "signal#{i}",
            type: "message",
            source: "/test",
            data: if(parent_id, do: %{parent_id: parent_id}, else: %{})
          }
        end)

      {:ok, dialogue} = Dialogue.from_signals(signals)

      # Verify each signal has correct depth based on its position
      Enum.with_index(signals, fn signal, index ->
        assert Dialogue.depth_of(dialogue, signal.id) == index
      end)
    end
  end

  property "children are always sorted by timestamp when timestamps exist" do
    check all(
            parent_id <- string(:alphanumeric, min_length: 1, max_length: 10),
            child_count <- integer(2..4)
          ) do
      # Create parent
      parent = %Signal{id: parent_id, type: "trigger", source: "/test"}
      dialogue = Dialogue.new(parent)

      # Create children with different timestamps
      base_time = DateTime.utc_now()

      children =
        1..child_count
        |> Enum.map(fn i ->
          timestamp = DateTime.add(base_time, i * 10, :second)

          %Signal{
            id: "child#{i}",
            type: "message",
            source: "/test",
            data: %{parent_id: parent_id},
            time: DateTime.to_iso8601(timestamp)
          }
        end)

      # Add children in random order
      shuffled_children = Enum.shuffle(children)

      dialogue_with_children =
        Enum.reduce(shuffled_children, dialogue, fn child, acc ->
          {:ok, updated} = Dialogue.add_signal(acc, child)
          updated
        end)

      # Get children and verify they're sorted by timestamp
      retrieved_children = Dialogue.children_of(dialogue_with_children, parent_id)

      child_timestamps =
        Enum.map(retrieved_children, fn child ->
          {:ok, dt, _} = DateTime.from_iso8601(child.time)
          dt
        end)

      # Timestamps should be in ascending order
      sorted_timestamps = Enum.sort(child_timestamps, DateTime)
      assert child_timestamps == sorted_timestamps
    end
  end

  property "max depth is enforced" do
    check all(attempt_depth <- integer(6..8)) do
      # Try to create a chain deeper than max depth (5)
      signals =
        1..attempt_depth
        |> Enum.map(fn i ->
          parent_id = if i == 1, do: nil, else: "signal#{i - 1}"

          %Signal{
            id: "signal#{i}",
            type: "message",
            source: "/test",
            data: if(parent_id, do: %{parent_id: parent_id}, else: %{})
          }
        end)

      case Dialogue.from_signals(signals) do
        {:ok, dialogue} ->
          # If successful, no signal should have depth > 5
          Enum.each(dialogue.signals, fn {_id, signal} ->
            assert Dialogue.depth_of(dialogue, signal.id) <= 5
          end)

        {:error, _} ->
          # Failure is acceptable for deep chains due to incremental adding
          # where depth_exceeded can occur
          true
      end
    end
  end

  property "immutability is preserved" do
    check all(
            root_id <- string(:alphanumeric, min_length: 1, max_length: 10),
            child_id <- string(:alphanumeric, min_length: 1, max_length: 10)
          ) do
      # Create original dialogue
      root = %Signal{id: root_id, type: "trigger", source: "/test"}
      original_dialogue = Dialogue.new(root)

      # Add a child
      child = %Signal{
        id: child_id,
        type: "message",
        source: "/test",
        data: %{parent_id: root_id}
      }

      {:ok, _updated_dialogue} = Dialogue.add_signal(original_dialogue, child)

      # Original should remain unchanged
      assert map_size(original_dialogue.signals) == 1
      assert MapSet.size(original_dialogue.orphans) == 0
      assert Dialogue.children_of(original_dialogue, root_id) == []
    end
  end
end
