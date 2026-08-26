defmodule Jido.Signal.Application do
  @moduledoc false
  use Application

  @doc """
  Starts the Jido Signal application.

  Initializes the Registry for named Buses.

  ## Parameters

  - `_type`: The application start type (ignored)
  - `_args`: Application start arguments (ignored)

  ## Returns

  `{:ok, pid}` where pid is the supervisor process ID
  """
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    children = [{Registry, keys: :unique, name: Jido.Signal.Registry}]

    opts = [strategy: :one_for_one, name: Jido.Signal.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
