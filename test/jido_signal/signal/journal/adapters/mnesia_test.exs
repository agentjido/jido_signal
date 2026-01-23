defmodule Jido.Signal.Journal.Adapters.MnesiaTest do
  use ExUnit.Case, async: false

  alias Jido.Signal
  alias Jido.Signal.ID
  alias Jido.Signal.Journal.Adapters.Mnesia
  alias Jido.Signal.Journal.Adapters.Mnesia.Tables

  @moduletag :mnesia

  defp create_test_signal(opts \\ []) do
    id = ID.generate!()
    type = Keyword.get(opts, :type, "test")
    source = Keyword.get(opts, :source, "test")
    subject = Keyword.get(opts, :subject, "test")
    time = Keyword.get(opts, :time, DateTime.utc_now())

    %Signal{
      id: id,
      type: type,
      source: source,
      time: time,
      subject: subject
    }
  end

  setup_all do
    :mnesia.stop()
    File.rm_rf("Mnesia.nonode@nohost")
    :mnesia.create_schema([node()])
    :mnesia.start()

    :ok = Mnesia.init()

    on_exit(fn ->
      :mnesia.stop()
      File.rm_rf("Mnesia.nonode@nohost")
    end)

    :ok
  end

  setup do
    # Use module atoms directly to avoid deprecation warning about
    # map.field notation when passing modules to :mnesia functions
    :mnesia.clear_table(Tables.Signal)
    :mnesia.clear_table(Tables.Cause)
    :mnesia.clear_table(Tables.Effect)
    :mnesia.clear_table(Tables.Conversation)
    :mnesia.clear_table(Tables.Checkpoint)
    :mnesia.clear_table(Tables.DLQ)

    :ok
  end

  test "init creates Mnesia tables" do
    mnesia_tables = :mnesia.system_info(:tables)

    assert Tables.Signal in mnesia_tables
    assert Tables.Cause in mnesia_tables
    assert Tables.Effect in mnesia_tables
    assert Tables.Conversation in mnesia_tables
    assert Tables.Checkpoint in mnesia_tables
  end

  test "put_signal/2 and get_signal/2" do
    signal = create_test_signal()
    assert :ok = Mnesia.put_signal(signal, nil)
    assert {:ok, ^signal} = Mnesia.get_signal(signal.id, nil)
  end

  test "get_signal/2 returns error for non-existent signal" do
    assert {:error, :not_found} = Mnesia.get_signal("non_existent", nil)
  end

  test "put_cause/3 and get_cause/2" do
    signal1 = create_test_signal()
    signal2 = create_test_signal()

    :ok = Mnesia.put_signal(signal1, nil)
    :ok = Mnesia.put_signal(signal2, nil)
    :ok = Mnesia.put_cause(signal1.id, signal2.id, nil)

    {:ok, cause_id} = Mnesia.get_cause(signal2.id, nil)
    assert cause_id == signal1.id
  end

  test "get_effects/2" do
    signal1 = create_test_signal()
    signal2 = create_test_signal()

    :ok = Mnesia.put_signal(signal1, nil)
    :ok = Mnesia.put_signal(signal2, nil)
    :ok = Mnesia.put_cause(signal1.id, signal2.id, nil)

    {:ok, effects} = Mnesia.get_effects(signal1.id, nil)
    assert MapSet.member?(effects, signal2.id)
  end

  test "get_effects/2 returns empty set for signal without effects" do
    {:ok, effects} = Mnesia.get_effects("non_existent", nil)
    assert effects == MapSet.new()
  end

  test "get_cause/2 returns error for signal without cause" do
    assert {:error, :not_found} = Mnesia.get_cause("non_existent", nil)
  end

  test "put_conversation/3 and get_conversation/2" do
    signal = create_test_signal()
    conversation_id = "test_conv_#{System.unique_integer([:positive, :monotonic])}"

    :ok = Mnesia.put_signal(signal, nil)
    :ok = Mnesia.put_conversation(conversation_id, signal.id, nil)

    {:ok, signals} = Mnesia.get_conversation(conversation_id, nil)
    assert MapSet.member?(signals, signal.id)
  end

  test "get_conversation/2 returns empty set for non-existent conversation" do
    {:ok, signals} = Mnesia.get_conversation("non_existent", nil)
    assert signals == MapSet.new()
  end

  test "put_checkpoint/3 and get_checkpoint/2" do
    subscription_id = "sub_#{System.unique_integer([:positive, :monotonic])}"
    checkpoint = 42

    :ok = Mnesia.put_checkpoint(subscription_id, checkpoint, nil)
    {:ok, retrieved} = Mnesia.get_checkpoint(subscription_id, nil)
    assert retrieved == checkpoint
  end

  test "get_checkpoint/2 returns error for non-existent checkpoint" do
    assert {:error, :not_found} = Mnesia.get_checkpoint("non_existent", nil)
  end

  test "delete_checkpoint/2" do
    subscription_id = "sub_#{System.unique_integer([:positive, :monotonic])}"
    checkpoint = 42

    :ok = Mnesia.put_checkpoint(subscription_id, checkpoint, nil)
    {:ok, ^checkpoint} = Mnesia.get_checkpoint(subscription_id, nil)

    :ok = Mnesia.delete_checkpoint(subscription_id, nil)
    assert {:error, :not_found} = Mnesia.get_checkpoint(subscription_id, nil)
  end

  test "multiple signals in conversation" do
    conversation_id = "test_conv_#{System.unique_integer([:positive, :monotonic])}"
    signal1 = create_test_signal()
    signal2 = create_test_signal()

    :ok = Mnesia.put_signal(signal1, nil)
    :ok = Mnesia.put_signal(signal2, nil)
    :ok = Mnesia.put_conversation(conversation_id, signal1.id, nil)
    :ok = Mnesia.put_conversation(conversation_id, signal2.id, nil)

    {:ok, signals} = Mnesia.get_conversation(conversation_id, nil)
    assert MapSet.member?(signals, signal1.id)
    assert MapSet.member?(signals, signal2.id)
  end

  test "multiple effects from same cause" do
    cause = create_test_signal()
    effect1 = create_test_signal()
    effect2 = create_test_signal()

    :ok = Mnesia.put_signal(cause, nil)
    :ok = Mnesia.put_signal(effect1, nil)
    :ok = Mnesia.put_signal(effect2, nil)
    :ok = Mnesia.put_cause(cause.id, effect1.id, nil)
    :ok = Mnesia.put_cause(cause.id, effect2.id, nil)

    {:ok, effects} = Mnesia.get_effects(cause.id, nil)
    assert MapSet.member?(effects, effect1.id)
    assert MapSet.member?(effects, effect2.id)
  end
end
