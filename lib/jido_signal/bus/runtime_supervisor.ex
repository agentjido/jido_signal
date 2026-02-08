defmodule Jido.Signal.Bus.RuntimeSupervisor do
  @moduledoc """
  Dynamic supervisor for per-bus runtime infrastructure.

  This supervisor owns runtime children created on-demand by each bus instance,
  such as the persistent subscription `DynamicSupervisor` and optional
  `PartitionSupervisor`.
  """
  use DynamicSupervisor

  @doc """
  Starts the runtime supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, :ok, name: name)
  end

  @impl DynamicSupervisor
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
