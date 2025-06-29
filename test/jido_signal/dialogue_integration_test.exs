defmodule Jido.Signal.DialogueIntegrationTest do
  use ExUnit.Case, async: true
  alias Jido.Signal.Dialogue
  alias Jido.Signal

  describe "end-to-end dialogue scenarios" do
    test "slack-style threaded conversation" do
      # Create a conversation like:
      # Original message
      # ├── Reply 1
      # │   └── Reply to Reply 1
      # └── Reply 2
      #     ├── Reply to Reply 2 (A)
      #     └── Reply to Reply 2 (B)

      signals = [
        %Signal{
          id: "original",
          type: "message.posted",
          source: "/chat",
          data: %{text: "What's the weather like?"},
          time: "2023-01-01T10:00:00Z"
        },
        %Signal{
          id: "reply1",
          type: "message.posted",
          source: "/chat",
          data: %{parent_id: "original", text: "It's sunny!"},
          time: "2023-01-01T10:01:00Z"
        },
        %Signal{
          id: "reply1_1",
          type: "message.posted",
          source: "/chat",
          data: %{parent_id: "reply1", text: "Great!"},
          time: "2023-01-01T10:02:00Z"
        },
        %Signal{
          id: "reply2",
          type: "message.posted",
          source: "/chat",
          data: %{parent_id: "original", text: "It's raining here"},
          time: "2023-01-01T10:03:00Z"
        },
        %Signal{
          id: "reply2_1",
          type: "message.posted",
          source: "/chat",
          data: %{parent_id: "reply2", text: "Bummer"},
          time: "2023-01-01T10:04:00Z"
        },
        %Signal{
          id: "reply2_2",
          type: "message.posted",
          source: "/chat",
          data: %{parent_id: "reply2", text: "At least it's good for plants"},
          time: "2023-01-01T10:05:00Z"
        }
      ]

      {:ok, dialogue} = Dialogue.from_signals(signals)

      # Check structure
      assert map_size(dialogue.signals) == 6
      assert MapSet.size(dialogue.orphans) == 0

      # Check depths
      assert Dialogue.depth_of(dialogue, "original") == 0
      assert Dialogue.depth_of(dialogue, "reply1") == 1
      assert Dialogue.depth_of(dialogue, "reply1_1") == 2
      assert Dialogue.depth_of(dialogue, "reply2") == 1
      assert Dialogue.depth_of(dialogue, "reply2_1") == 2
      assert Dialogue.depth_of(dialogue, "reply2_2") == 2

      # Check children relationships
      original_children = Dialogue.children_of(dialogue, "original")
      assert length(original_children) == 2
      assert Enum.map(original_children, & &1.id) == ["reply1", "reply2"]

      reply2_children = Dialogue.children_of(dialogue, "reply2")
      assert length(reply2_children) == 2
      assert Enum.map(reply2_children, & &1.id) == ["reply2_1", "reply2_2"]

      # Check threaded view
      threads = Dialogue.to_threaded_list(dialogue)
      assert length(threads) == 3

      # Find and verify each thread
      thread_ids = Enum.map(threads, fn thread -> Enum.map(thread, & &1.id) end)
      assert ["original", "reply1", "reply1_1"] in thread_ids
      assert ["original", "reply2", "reply2_1"] in thread_ids
      assert ["original", "reply2", "reply2_2"] in thread_ids
    end

    test "out-of-order signal processing" do
      # Add signals in completely random order
      signals = [
        %Signal{
          id: "level3",
          type: "message",
          source: "/test",
          data: %{parent_id: "level2", text: "Third level"}
        },
        %Signal{
          id: "root",
          type: "trigger",
          source: "/test",
          data: %{text: "Root message"}
        },
        %Signal{
          id: "level2",
          type: "message",
          source: "/test",
          data: %{parent_id: "level1", text: "Second level"}
        },
        %Signal{
          id: "level1",
          type: "message",
          source: "/test",
          data: %{parent_id: "root", text: "First level"}
        }
      ]

      {:ok, dialogue} = Dialogue.from_signals(signals)

      # Should create a linear chain despite out-of-order input
      assert map_size(dialogue.signals) == 4
      assert MapSet.size(dialogue.orphans) == 0

      # Verify the chain
      assert Dialogue.depth_of(dialogue, "root") == 0
      assert Dialogue.depth_of(dialogue, "level1") == 1
      assert Dialogue.depth_of(dialogue, "level2") == 2
      assert Dialogue.depth_of(dialogue, "level3") == 3

      # Should have one thread with all 4 signals
      threads = Dialogue.to_threaded_list(dialogue)
      assert length(threads) == 1

      thread = List.first(threads)
      thread_ids = Enum.map(thread, & &1.id)
      assert thread_ids == ["root", "level1", "level2", "level3"]
    end

    test "maximum depth enforcement" do
      # Try to create a 6-level deep chain (should be rejected)
      signals = [
        %Signal{id: "root", type: "trigger", source: "/test"},
        %Signal{
          id: "level1",
          type: "message",
          source: "/test",
          data: %{parent_id: "root"}
        },
        %Signal{
          id: "level2",
          type: "message",
          source: "/test",
          data: %{parent_id: "level1"}
        },
        %Signal{
          id: "level3",
          type: "message",
          source: "/test",
          data: %{parent_id: "level2"}
        },
        %Signal{
          id: "level4",
          type: "message",
          source: "/test",
          data: %{parent_id: "level3"}
        },
        %Signal{
          id: "level5",
          type: "message",
          source: "/test",
          data: %{parent_id: "level4"}
        },
        %Signal{
          id: "level6",
          type: "message",
          source: "/test",
          data: %{parent_id: "level5"}
        }
      ]

      # Should succeed up to level 5, reject level 6
      case Dialogue.from_signals(signals) do
        {:ok, dialogue} ->
          # If it succeeds, level6 should not be in the dialogue
          assert not Map.has_key?(dialogue.signals, "level6")
          assert Map.has_key?(dialogue.signals, "level5")

        {:error, reason} ->
          # If it fails, it should be due to depth or orphans
          assert reason in [:depth_exceeded, {:orphans, ["level6"]}]
      end
    end

    test "multiple conversation roots" do
      # Two separate conversation threads
      signals = [
        %Signal{id: "root1", type: "trigger", source: "/chat1"},
        %Signal{
          id: "root1_child",
          type: "message",
          source: "/chat1",
          data: %{parent_id: "root1"}
        },
        %Signal{id: "root2", type: "trigger", source: "/chat2"},
        %Signal{
          id: "root2_child",
          type: "message",
          source: "/chat2",
          data: %{parent_id: "root2"}
        }
      ]

      {:ok, dialogue} = Dialogue.from_signals(signals)

      # Should have 2 separate threads
      threads = Dialogue.to_threaded_list(dialogue)
      assert length(threads) == 2

      # Each thread should have 2 signals
      Enum.each(threads, fn thread ->
        assert length(thread) == 2
      end)

      # Verify roots
      root_ids =
        threads
        |> Enum.map(&List.first/1)
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert root_ids == ["root1", "root2"]
    end

    test "timestamp ordering of children" do
      base_time = ~U[2023-01-01 10:00:00Z]

      signals = [
        %Signal{id: "root", type: "trigger", source: "/test"},
        %Signal{
          id: "child_c",
          type: "message",
          source: "/test",
          data: %{parent_id: "root"},
          time: DateTime.add(base_time, 30, :second) |> DateTime.to_iso8601()
        },
        %Signal{
          id: "child_a",
          type: "message",
          source: "/test",
          data: %{parent_id: "root"},
          time: DateTime.add(base_time, 10, :second) |> DateTime.to_iso8601()
        },
        %Signal{
          id: "child_b",
          type: "message",
          source: "/test",
          data: %{parent_id: "root"},
          time: DateTime.add(base_time, 20, :second) |> DateTime.to_iso8601()
        }
      ]

      {:ok, dialogue} = Dialogue.from_signals(signals)

      children = Dialogue.children_of(dialogue, "root")
      child_ids = Enum.map(children, & &1.id)

      # Should be sorted by timestamp: a, b, c
      assert child_ids == ["child_a", "child_b", "child_c"]
    end

    test "immutability across operations" do
      trigger = %Signal{id: "root", type: "trigger", source: "/test"}
      original_dialogue = Dialogue.new(trigger)

      # Capture original state
      original_signal_count = map_size(original_dialogue.signals)
      original_orphan_count = MapSet.size(original_dialogue.orphans)

      # Perform various operations
      child1 = %Signal{
        id: "child1",
        type: "message",
        source: "/test",
        data: %{parent_id: "root"}
      }

      {:ok, dialogue_v2} = Dialogue.add_signal(original_dialogue, child1)

      child2 = %Signal{
        id: "child2",
        type: "message",
        source: "/test",
        data: %{parent_id: "root"}
      }

      {:ok, _dialogue_v3} = Dialogue.add_signal(dialogue_v2, child2)

      # Original dialogue should be unchanged
      assert map_size(original_dialogue.signals) == original_signal_count
      assert MapSet.size(original_dialogue.orphans) == original_orphan_count
      assert Dialogue.children_of(original_dialogue, "root") == []

      # Second version should only have one child
      assert map_size(dialogue_v2.signals) == 2
      assert length(Dialogue.children_of(dialogue_v2, "root")) == 1
    end
  end
end
