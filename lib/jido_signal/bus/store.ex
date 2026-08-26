defmodule Jido.Signal.Bus.Store do
  @moduledoc """
  Defines the small storage boundary that the Signal Bus owns.

  A store keeps ordered Bus records and durable subscription definitions. A
  durable definition contains its stable ID, path, cursor, creation time, and
  `format_version: 1`. Records also use `format_version: 1`.

  `list_subscriptions/1` must return definitions in creation order. `append/2`
  must accept all records or none. The Bus stores the returned state and passes
  it to the next callback.

  Only `Jido.Signal.Bus.Store.Memory` is included. A custom adapter can keep an
  external resource in its state when records must survive a Bus restart.
  """

  @type state :: term()
  @type record :: %{required(String.t()) => term()}
  @type subscription :: %{required(String.t()) => term()}
  @type subscription_id :: String.t()

  @callback init(keyword()) :: {:ok, state()} | {:error, term()}
  @callback append([record()], state()) :: {:ok, state()} | {:error, term()}
  @doc """
  Reads records after an exclusive `:after_cursor`.

  The optional `:path` filters Signal types. The optional `:limit` is a positive
  integer or `:infinity`.
  """
  @callback read(keyword(), state()) :: {:ok, [record()]} | {:error, term()}
  @callback latest_cursor(state()) :: {:ok, non_neg_integer()} | {:error, term()}
  @callback list_subscriptions(state()) :: {:ok, [subscription()]} | {:error, term()}
  @callback put_subscription(subscription(), state()) :: {:ok, state()} | {:error, term()}
  @callback delete_subscription(subscription_id(), state()) :: {:ok, state()} | {:error, term()}
end
