defmodule Jido.Signal.Bus.PersistentRef do
  @moduledoc """
  Stable addressing for persistent subscription processes.

  `PersistentRef` encapsulates:
  - a stable registry reference (`:via` tuple) used as the authoritative target
  - an optional cached pid for diagnostics/debugging compatibility
  """

  alias Jido.Signal.Bus.PersistentSubscription

  @enforce_keys [:bus_name, :subscription_id, :via]
  defstruct [:bus_name, :subscription_id, :via, :pid]

  @typedoc "Stable reference to a persistent subscription process"
  @type t :: %__MODULE__{
          bus_name: atom() | binary(),
          subscription_id: String.t(),
          via: {:via, Registry, {module(), tuple()}},
          pid: pid() | nil
        }

  @doc """
  Builds a new `PersistentRef`.
  """
  @spec new(atom() | binary(), String.t(), keyword(), pid() | nil) :: t()
  def new(bus_name, subscription_id, opts \\ [], pid \\ nil) do
    %__MODULE__{
      bus_name: bus_name,
      subscription_id: subscription_id,
      via: PersistentSubscription.via_tuple(bus_name, subscription_id, opts),
      pid: pid
    }
  end

  @doc """
  Returns a migration-friendly persistent reference from subscription data.
  """
  @spec from_subscription(map(), atom() | binary(), keyword()) :: t() | nil
  def from_subscription(subscription, bus_name, opts \\ []) when is_map(subscription) do
    cached_pid = Map.get(subscription, :persistence_pid)
    subscription_id = Map.get(subscription, :id)

    case Map.get(subscription, :persistence_ref) do
      %__MODULE__{} = ref ->
        with_pid(ref, cached_pid || ref.pid)

      via = {:via, Registry, _} ->
        if is_binary(subscription_id) do
          %__MODULE__{
            bus_name: bus_name,
            subscription_id: subscription_id,
            via: via,
            pid: cached_pid
          }
        else
          nil
        end

      _ ->
        if is_binary(subscription_id) do
          new(bus_name, subscription_id, opts, cached_pid)
        else
          nil
        end
    end
  end

  @doc """
  Returns the stable target to call/cast.
  """
  @spec target(t() | {:via, Registry, term()} | pid() | nil) ::
          {:via, Registry, term()} | pid() | nil
  def target(%__MODULE__{via: via}), do: via
  def target({:via, Registry, _} = via), do: via
  def target(pid) when is_pid(pid), do: pid
  def target(_), do: nil

  @doc """
  Resolves the current pid for this reference.
  """
  @spec resolve_pid(t()) :: pid() | nil
  def resolve_pid(%__MODULE__{via: via}), do: GenServer.whereis(via)

  @doc """
  Updates the cached pid field.
  """
  @spec with_pid(t(), pid() | nil) :: t()
  def with_pid(%__MODULE__{} = ref, pid), do: %{ref | pid: pid}
end
