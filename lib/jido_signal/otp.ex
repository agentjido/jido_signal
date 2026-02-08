defmodule Jido.Signal.OTP do
  @moduledoc false

  alias Jido.Signal.Retry

  @spec start_link_with_retry((-> term()), keyword()) :: term()
  def start_link_with_retry(start_fun, opts \\ []) when is_function(start_fun, 0) do
    attempts = Keyword.get(opts, :attempts, 3)
    delay_ms = Keyword.get(opts, :delay_ms, 10)
    on_exhausted = Keyword.get(opts, :on_exhausted, {:error, :name_conflict})

    Retry.until(attempts, fn -> normalize_start_link_result(start_fun.()) end,
      delay_ms: delay_ms,
      factor: 1.0,
      on_exhausted: on_exhausted
    )
  end

  defp normalize_start_link_result({:ok, pid}) when is_pid(pid), do: {:ok, pid}

  defp normalize_start_link_result({:error, {:already_started, pid}}) when is_pid(pid),
    do: {:ok, pid}

  defp normalize_start_link_result(other), do: other
end
