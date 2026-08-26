defmodule Jido.Signal.Bus.Store do
  @moduledoc """
  Defines the storage boundary that the Signal Bus owns.

  A store keeps the bounded replay log, persistent-subscription checkpoints,
  and dead-letter entries. The Bus passes the returned store state to the next
  callback. A store can use this state directly or keep an external resource in
  it.

  Stored records are maps with `format_version: 1`. A custom store must keep
  these maps unchanged so that a later Bus version can migrate them.
  """

  @type state :: term()
  @type record :: map()
  @type checkpoint_key :: String.t()
  @type subscription_id :: String.t()

  @callback init(keyword()) :: {:ok, state()} | {:error, term()}
  @callback append([record()], state()) :: {:ok, state()} | {:error, term()}
  @callback read(keyword(), state()) :: {:ok, [record()]} | {:error, term()}

  @callback get_checkpoint(checkpoint_key(), state()) ::
              {:ok, non_neg_integer() | nil} | {:error, term()}
  @callback put_checkpoint(checkpoint_key(), non_neg_integer(), state()) ::
              {:ok, state()} | {:error, term()}
  @callback delete_checkpoint(checkpoint_key(), state()) :: {:ok, state()} | {:error, term()}

  @callback put_dlq(subscription_id(), record(), state()) ::
              {:ok, state()} | {:error, term()}
  @callback list_dlq(subscription_id(), state()) :: {:ok, [record()]} | {:error, term()}
  @callback delete_dlq(subscription_id(), [String.t()], state()) ::
              {:ok, state()} | {:error, term()}
  @callback clear_dlq(subscription_id(), state()) :: {:ok, state()} | {:error, term()}
end
