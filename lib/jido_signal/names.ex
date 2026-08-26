defmodule Jido.Signal.Names do
  @moduledoc false

  @type opts :: keyword()

  @doc false
  @spec registry(opts()) :: atom()
  def registry(opts) do
    scoped(opts, Jido.Signal.Registry)
  end

  @doc false
  @spec task_supervisor(opts()) :: atom()
  def task_supervisor(opts) do
    scoped(opts, Jido.Signal.TaskSupervisor)
  end

  @doc false
  @spec supervisor(opts()) :: atom()
  def supervisor(opts) do
    scoped(opts, Jido.Signal.Supervisor)
  end

  defp scoped(opts, default) when is_list(opts) and is_atom(default) do
    case Keyword.get(opts, :jido) do
      nil ->
        default

      instance when is_atom(instance) ->
        # Get the relative path after Jido (e.g., Signal.Registry from Jido.Signal.Registry)
        default_parts = Module.split(default)

        relative_parts =
          case default_parts do
            ["Jido" | rest] -> rest
            parts -> parts
          end

        Module.concat([instance | relative_parts])
    end
  end
end
