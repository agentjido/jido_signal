defmodule Jido.Signal.Bus.Store.Memory do
  @moduledoc false

  @behaviour Jido.Signal.Bus.Store

  @default_max_records 100_000

  @impl true
  def init(opts) do
    max_records = Keyword.get(opts, :max_records, @default_max_records)

    if is_integer(max_records) and max_records > 0 do
      {:ok, %{records: [], checkpoints: %{}, dlq: %{}, max_records: max_records}}
    else
      {:error, {:invalid_option, :max_records}}
    end
  end

  @impl true
  def append(records, state) when is_list(records) do
    retained = Enum.take(state.records ++ records, -state.max_records)
    {:ok, %{state | records: retained}}
  end

  @impl true
  def read(opts, state) do
    after_cursor = Keyword.get(opts, :after_cursor, -1)
    limit = Keyword.get(opts, :limit, :infinity)

    records = Enum.filter(state.records, &(Map.fetch!(&1, "cursor") > after_cursor))
    records = if limit == :infinity, do: records, else: Enum.take(records, limit)

    {:ok, records}
  end

  @impl true
  def get_checkpoint(key, state), do: {:ok, Map.get(state.checkpoints, key)}

  @impl true
  def put_checkpoint(key, cursor, state) do
    {:ok, %{state | checkpoints: Map.put(state.checkpoints, key, cursor)}}
  end

  @impl true
  def delete_checkpoint(key, state) do
    {:ok, %{state | checkpoints: Map.delete(state.checkpoints, key)}}
  end

  @impl true
  def put_dlq(subscription_id, entry, state) do
    entries = Map.get(state.dlq, subscription_id, []) ++ [entry]
    {:ok, %{state | dlq: Map.put(state.dlq, subscription_id, entries)}}
  end

  @impl true
  def list_dlq(subscription_id, state) do
    {:ok, Map.get(state.dlq, subscription_id, [])}
  end

  @impl true
  def delete_dlq(subscription_id, entry_ids, state) do
    entry_ids = MapSet.new(entry_ids)

    entries =
      state.dlq
      |> Map.get(subscription_id, [])
      |> Enum.reject(&MapSet.member?(entry_ids, Map.fetch!(&1, "id")))

    {:ok, %{state | dlq: Map.put(state.dlq, subscription_id, entries)}}
  end

  @impl true
  def clear_dlq(subscription_id, state) do
    {:ok, %{state | dlq: Map.delete(state.dlq, subscription_id)}}
  end
end
