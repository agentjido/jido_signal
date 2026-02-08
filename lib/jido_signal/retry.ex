defmodule Jido.Signal.Retry do
  @moduledoc """
  Shared retry/backoff helper for transient runtime operations.
  """

  @type retry_fun :: (-> :retry | term())

  @doc """
  Re-runs `fun` while it returns `:retry`.

  ## Options
  - `:delay_ms` - Initial delay between retries (default: 10)
  - `:factor` - Backoff factor applied after each retry (default: 1.0)
  - `:max_delay_ms` - Maximum retry delay (default: `:delay_ms`)
  - `:on_exhausted` - Return value when retries are exhausted (default: `:retry_exhausted`)
  """
  @spec until(pos_integer(), retry_fun(), keyword()) :: term()
  def until(attempts, fun, opts \\ [])
      when is_integer(attempts) and attempts > 0 and is_function(fun, 0) do
    delay_ms = Keyword.get(opts, :delay_ms, 10)
    factor = Keyword.get(opts, :factor, 1.0)
    max_delay_ms = Keyword.get(opts, :max_delay_ms, delay_ms)
    on_exhausted = Keyword.get(opts, :on_exhausted, :retry_exhausted)

    do_until(1, attempts, delay_ms, factor, max_delay_ms, on_exhausted, fun)
  end

  defp do_until(attempt, attempts, _delay_ms, _factor, _max_delay_ms, on_exhausted, _fun)
       when attempt > attempts do
    on_exhausted
  end

  defp do_until(attempt, attempts, delay_ms, factor, max_delay_ms, on_exhausted, fun) do
    case fun.() do
      :retry ->
        if attempt >= attempts do
          on_exhausted
        else
          Process.sleep(delay_ms)
          next_delay = min(round(delay_ms * factor), max_delay_ms)
          do_until(attempt + 1, attempts, next_delay, factor, max_delay_ms, on_exhausted, fun)
        end

      result ->
        result
    end
  end
end
