defmodule Jido.Signal.DialogueTest do
  use ExUnit.Case, async: true
  alias Jido.Signal.Dialogue
  alias Jido.Signal

  doctest Dialogue

  describe "new/1" do
    test "creates a dialogue with a trigger signal" do
      trigger = %Signal{id: "root", type: "conversation.started", source: "/chat"}
      dialogue = Dialogue.new(trigger)

      assert %Dialogue{} = dialogue
      assert Map.has_key?(dialogue.signals, "root")
      assert dialogue.signals["root"] == trigger
      assert Graph.has_vertex?(dialogue.graph, "root")
    end
  end

  describe "from_signals/1" do
    test "creates dialogue from list of signals in order" do
      signals = [
        %Signal{id: "1", type: "trigger", source: "/chat"},
        %Signal{
          id: "2",
          type: "reply",
          source: "/chat",
          data: %{parent_id: "1", text: "Hello"}
        },
        %Signal{
          id: "3",
          type: "reply",
          source: "/chat",
          data: %{parent_id: "1", text: "World"}
        }
      ]

      {:ok, dialogue} = Dialogue.from_signals(signals)

      assert map_size(dialogue.signals) == 3
      assert MapSet.size(dialogue.orphans) == 0

      children = Dialogue.children_of(dialogue, "1")
      assert length(children) == 2
      assert Enum.any?(children, &(&1.id == "2"))
      assert Enum.any?(children, &(&1.id == "3"))
    end

    test "handles out-of-order signals correctly" do
      # Child signal comes before parent
      signals = [
        %Signal{id: "1", type: "trigger", source: "/chat"},
        %Signal{
          id: "3",
          type: "reply",
          source: "/chat",
          data: %{parent_id: "2", text: "Grandchild"}
        },
        %Signal{
          id: "2",
          type: "reply",
          source: "/chat",
          data: %{parent_id: "1", text: "Child"}
        }
      ]

      {:ok, dialogue} = Dialogue.from_signals(signals)

      assert map_size(dialogue.signals) == 3
      assert MapSet.size(dialogue.orphans) == 0

      # Verify structure
      children_of_1 = Dialogue.children_of(dialogue, "1")
      assert length(children_of_1) == 1
      assert List.first(children_of_1).id == "2"

      children_of_2 = Dialogue.children_of(dialogue, "2")
      assert length(children_of_2) == 1
      assert List.first(children_of_2).id == "3"
    end

    test "returns error when orphans remain unresolved" do
      signals = [
        %Signal{id: "1", type: "trigger", source: "/chat"},
        %Signal{
          id: "2",
          type: "reply",
          source: "/chat",
          data: %{parent_id: "missing", text: "Orphan"}
        }
      ]

      assert {:error, {:orphans, ["2"]}} = Dialogue.from_signals(signals)
    end

    test "returns error with empty signal list" do
      assert {:error, :empty_signal_list} = Dialogue.from_signals([])
    end
  end

  describe "add_signal/2" do
    setup do
      trigger = %Signal{id: "root", type: "conversation.started", source: "/chat"}
      dialogue = Dialogue.new(trigger)
      {:ok, dialogue: dialogue, trigger: trigger}
    end

    test "adds child signal to existing parent", %{dialogue: dialogue} do
      child = %Signal{
        id: "child1",
        type: "message.sent",
        source: "/chat",
        data: %{parent_id: "root", text: "Hello"}
      }

      {:ok, updated} = Dialogue.add_signal(dialogue, child)

      assert Map.has_key?(updated.signals, "child1")
      assert Graph.edge(updated.graph, "root", "child1") != nil

      children = Dialogue.children_of(updated, "root")
      assert length(children) == 1
      assert List.first(children).id == "child1"
    end

    test "handles orphan signal (parent doesn't exist yet)", %{dialogue: dialogue} do
      orphan = %Signal{
        id: "orphan",
        type: "message.sent",
        source: "/chat",
        data: %{parent_id: "missing", text: "Orphaned"}
      }

      {:ok, updated} = Dialogue.add_signal(dialogue, orphan)

      assert Map.has_key?(updated.signals, "orphan")
      assert MapSet.member?(updated.orphans, "orphan")
      assert not Graph.has_vertex?(updated.graph, "orphan")
    end

    test "resolves orphan when parent is added later", %{dialogue: dialogue} do
      # Add orphan first
      orphan = %Signal{
        id: "orphan",
        type: "message.sent",
        source: "/chat",
        data: %{parent_id: "parent", text: "Orphaned"}
      }

      {:ok, dialogue_with_orphan} = Dialogue.add_signal(dialogue, orphan)
      assert MapSet.member?(dialogue_with_orphan.orphans, "orphan")

      # Add parent
      parent = %Signal{
        id: "parent",
        type: "message.sent",
        source: "/chat",
        data: %{parent_id: "root", text: "Parent"}
      }

      {:ok, final_dialogue} = Dialogue.add_signal(dialogue_with_orphan, parent)

      # Orphan should be resolved
      assert MapSet.size(final_dialogue.orphans) == 0
      assert Graph.edge(final_dialogue.graph, "parent", "orphan") != nil

      children = Dialogue.children_of(final_dialogue, "parent")
      assert length(children) == 1
      assert List.first(children).id == "orphan"
    end

    test "prevents duplicate signal IDs", %{dialogue: dialogue, trigger: trigger} do
      assert {:error, :duplicate} = Dialogue.add_signal(dialogue, trigger)
    end

    test "enforces maximum depth of 5", %{dialogue: dialogue} do
      # Build a chain of depth 5 (root + 5 levels)
      levels = [
        %Signal{
          id: "level1",
          type: "message",
          source: "/chat",
          data: %{parent_id: "root"}
        },
        %Signal{
          id: "level2",
          type: "message",
          source: "/chat",
          data: %{parent_id: "level1"}
        },
        %Signal{
          id: "level3",
          type: "message",
          source: "/chat",
          data: %{parent_id: "level2"}
        },
        %Signal{
          id: "level4",
          type: "message",
          source: "/chat",
          data: %{parent_id: "level3"}
        },
        %Signal{
          id: "level5",
          type: "message",
          source: "/chat",
          data: %{parent_id: "level4"}
        }
      ]

      # Add all levels successfully
      final_dialogue =
        Enum.reduce(levels, dialogue, fn signal, acc ->
          {:ok, updated} = Dialogue.add_signal(acc, signal)
          updated
        end)

      # Verify depth 5 signal exists
      assert Dialogue.depth_of(final_dialogue, "level5") == 5

      # Try to add level 6 - should fail
      level6 = %Signal{
        id: "level6",
        type: "message",
        source: "/chat",
        data: %{parent_id: "level5"}
      }

      assert {:error, :depth_exceeded} = Dialogue.add_signal(final_dialogue, level6)
    end
  end

  describe "children_of/2" do
    setup do
      signals = [
        %Signal{id: "root", type: "trigger", source: "/chat"},
        %Signal{
          id: "child1",
          type: "reply",
          source: "/chat",
          data: %{parent_id: "root"},
          time: "2023-01-01T10:00:00Z"
        },
        %Signal{
          id: "child2",
          type: "reply",
          source: "/chat",
          data: %{parent_id: "root"},
          time: "2023-01-01T11:00:00Z"
        }
      ]

      {:ok, dialogue} = Dialogue.from_signals(signals)
      {:ok, dialogue: dialogue}
    end

    test "returns children sorted by timestamp", %{dialogue: dialogue} do
      children = Dialogue.children_of(dialogue, "root")

      assert length(children) == 2
      assert List.first(children).id == "child1"
      assert List.last(children).id == "child2"
    end

    test "returns empty list for signal with no children", %{dialogue: dialogue} do
      children = Dialogue.children_of(dialogue, "child1")
      assert children == []
    end

    test "returns empty list for non-existent signal", %{dialogue: dialogue} do
      children = Dialogue.children_of(dialogue, "missing")
      assert children == []
    end
  end

  describe "ancestors_of/2" do
    setup do
      signals = [
        %Signal{id: "root", type: "trigger", source: "/chat"},
        %Signal{
          id: "child",
          type: "reply",
          source: "/chat",
          data: %{parent_id: "root"}
        },
        %Signal{
          id: "grandchild",
          type: "reply",
          source: "/chat",
          data: %{parent_id: "child"}
        }
      ]

      {:ok, dialogue} = Dialogue.from_signals(signals)
      {:ok, dialogue: dialogue}
    end

    test "returns ancestors in root-first order", %{dialogue: dialogue} do
      ancestors = Dialogue.ancestors_of(dialogue, "grandchild")

      assert length(ancestors) == 2
      assert List.first(ancestors).id == "root"
      assert List.last(ancestors).id == "child"
    end

    test "returns empty list for root signal", %{dialogue: dialogue} do
      ancestors = Dialogue.ancestors_of(dialogue, "root")
      assert ancestors == []
    end

    test "returns single ancestor for direct child", %{dialogue: dialogue} do
      ancestors = Dialogue.ancestors_of(dialogue, "child")

      assert length(ancestors) == 1
      assert List.first(ancestors).id == "root"
    end
  end

  describe "depth_of/2" do
    setup do
      signals = [
        %Signal{id: "root", type: "trigger", source: "/chat"},
        %Signal{
          id: "child",
          type: "reply",
          source: "/chat",
          data: %{parent_id: "root"}
        },
        %Signal{
          id: "grandchild",
          type: "reply",
          source: "/chat",
          data: %{parent_id: "child"}
        }
      ]

      {:ok, dialogue} = Dialogue.from_signals(signals)
      {:ok, dialogue: dialogue}
    end

    test "returns correct depth for each level", %{dialogue: dialogue} do
      assert Dialogue.depth_of(dialogue, "root") == 0
      assert Dialogue.depth_of(dialogue, "child") == 1
      assert Dialogue.depth_of(dialogue, "grandchild") == 2
    end

    test "returns 0 for non-existent signal", %{dialogue: dialogue} do
      assert Dialogue.depth_of(dialogue, "missing") == 0
    end
  end

  describe "to_threaded_list/1" do
    test "creates threaded view of simple conversation" do
      signals = [
        %Signal{id: "root", type: "trigger", source: "/chat"},
        %Signal{
          id: "child1",
          type: "reply",
          source: "/chat",
          data: %{parent_id: "root"}
        },
        %Signal{
          id: "child2",
          type: "reply",
          source: "/chat",
          data: %{parent_id: "root"}
        }
      ]

      {:ok, dialogue} = Dialogue.from_signals(signals)
      threads = Dialogue.to_threaded_list(dialogue)

      # Should have 2 threads: root->child1 and root->child2
      assert length(threads) == 2

      # Each thread should start with root
      Enum.each(threads, fn thread ->
        assert List.first(thread).id == "root"
        assert length(thread) == 2
      end)
    end

    test "creates threaded view of branching conversation" do
      signals = [
        %Signal{id: "root", type: "trigger", source: "/chat"},
        %Signal{
          id: "branch1",
          type: "reply",
          source: "/chat",
          data: %{parent_id: "root"}
        },
        %Signal{
          id: "branch1_child",
          type: "reply",
          source: "/chat",
          data: %{parent_id: "branch1"}
        },
        %Signal{
          id: "branch2",
          type: "reply",
          source: "/chat",
          data: %{parent_id: "root"}
        }
      ]

      {:ok, dialogue} = Dialogue.from_signals(signals)
      threads = Dialogue.to_threaded_list(dialogue)

      # Should have 2 threads: root->branch1->branch1_child and root->branch2
      assert length(threads) == 2

      # Find the longer thread
      longer_thread = Enum.find(threads, &(length(&1) == 3))
      shorter_thread = Enum.find(threads, &(length(&1) == 2))

      assert longer_thread != nil
      assert shorter_thread != nil

      # Verify thread structure
      assert List.first(longer_thread).id == "root"
      assert Enum.at(longer_thread, 1).id == "branch1"
      assert List.last(longer_thread).id == "branch1_child"

      assert List.first(shorter_thread).id == "root"
      assert List.last(shorter_thread).id == "branch2"
    end

    test "handles single signal dialogue" do
      trigger = %Signal{id: "root", type: "trigger", source: "/chat"}
      dialogue = Dialogue.new(trigger)
      threads = Dialogue.to_threaded_list(dialogue)

      assert length(threads) == 1
      assert length(List.first(threads)) == 1
      assert List.first(List.first(threads)).id == "root"
    end

    test "handles multiple root signals" do
      # Create dialogue with multiple disconnected trees
      root1 = %Signal{id: "root1", type: "trigger", source: "/chat"}
      root2 = %Signal{id: "root2", type: "trigger", source: "/chat"}

      dialogue1 = Dialogue.new(root1)
      {:ok, dialogue2} = Dialogue.add_signal(dialogue1, root2)

      threads = Dialogue.to_threaded_list(dialogue2)

      assert length(threads) == 2
      thread_roots = Enum.map(threads, fn thread -> List.first(thread).id end)
      assert "root1" in thread_roots
      assert "root2" in thread_roots
    end
  end

  describe "edge cases and error handling" do
    test "handles signals with different parent_id formats" do
      trigger = %Signal{id: "root", type: "trigger", source: "/chat"}
      dialogue = Dialogue.new(trigger)

      # String key in data
      child1 = %Signal{
        id: "child1",
        type: "reply",
        source: "/chat",
        data: %{"parent_id" => "root"}
      }

      # Atom key in data
      child2 = %Signal{
        id: "child2",
        type: "reply",
        source: "/chat",
        data: %{parent_id: "root"}
      }

      # No parent_id in data
      child3 = %Signal{
        id: "child3",
        type: "reply",
        source: "/chat",
        data: %{message: "standalone"}
      }

      {:ok, dialogue} = Dialogue.add_signal(dialogue, child1)
      {:ok, dialogue} = Dialogue.add_signal(dialogue, child2)
      {:ok, dialogue} = Dialogue.add_signal(dialogue, child3)

      # Both child1 and child2 should be children of root
      children = Dialogue.children_of(dialogue, "root")
      assert length(children) == 2

      # child3 should be a root (no parent)
      assert Graph.in_degree(dialogue.graph, "child3") == 0
    end

    test "handles signals with malformed timestamps" do
      signals = [
        %Signal{id: "root", type: "trigger", source: "/chat", time: "invalid"},
        %Signal{
          id: "child",
          type: "reply",
          source: "/chat",
          data: %{parent_id: "root"},
          time: nil
        }
      ]

      assert {:ok, dialogue} = Dialogue.from_signals(signals)
      children = Dialogue.children_of(dialogue, "root")
      assert length(children) == 1
    end

    test "immutability - original dialogue unchanged after operations" do
      trigger = %Signal{id: "root", type: "trigger", source: "/chat"}
      original_dialogue = Dialogue.new(trigger)

      child = %Signal{
        id: "child",
        type: "reply",
        source: "/chat",
        data: %{parent_id: "root"}
      }

      {:ok, _updated_dialogue} = Dialogue.add_signal(original_dialogue, child)

      # Original should remain unchanged
      assert map_size(original_dialogue.signals) == 1
      assert MapSet.size(original_dialogue.orphans) == 0
      assert Dialogue.children_of(original_dialogue, "root") == []
    end
  end
end
