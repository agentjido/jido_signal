alias Jido.Signal
alias Jido.Signal.Router

sizes =
  case System.argv() do
    [] -> [1_000, 10_000, 100_000]
    args -> Enum.map(args, &String.to_integer/1)
  end

iterations = fn
  size when size <= 1_000 -> 5_000
  size when size <= 10_000 -> 1_000
  _size -> 100
end

percentile = fn samples, percentile ->
  index = ceil(length(samples) * percentile) - 1
  Enum.at(samples, max(index, 0))
end

IO.puts("Router lookup benchmark")
IO.puts("Elixir #{System.version()} / OTP #{System.otp_release()}")
scenarios = [
  exact: fn size ->
    expected = div(size, 2)

    {
      for(index <- 1..size, do: {"bench.event.#{index}", index}),
      %Signal{id: "bench", source: "/bench", type: "bench.event.#{expected}"},
      [expected]
    }
  end,
  single: fn size ->
    expected = div(size, 2)

    {
      for(index <- 1..size, do: {"bench.#{index}.*.completed", index}),
      %Signal{id: "bench", source: "/bench", type: "bench.#{expected}.job.completed"},
      [expected]
    }
  end,
  multi: fn size ->
    expected = div(size, 2)

    {
      for(index <- 1..size, do: {"bench.#{index}.**.completed", index}),
      %Signal{id: "bench", source: "/bench", type: "bench.#{expected}.one.two.completed"},
      [expected]
    }
  end,
  mixed: fn size ->
    exact_count = max(trunc(size * 0.90) - 1, 0)
    single_count = max(trunc(size * 0.09) - 1, 0)
    multi_count = size - exact_count - single_count - 3

    exact_routes = for index <- 1..exact_count, do: {"exact.#{index}", {:exact, index}}
    single_routes = for index <- 1..single_count, do: {"single.#{index}.*", {:single, index}}
    multi_routes = for index <- 1..multi_count, do: {"multi.#{index}.**", {:multi, index}}

    routes =
      exact_routes ++
        single_routes ++
        multi_routes ++
        [
          {"bench.target.completed", :exact},
          {"bench.*.completed", :single},
          {"bench.**", :multi}
        ]

    {
      routes,
      %Signal{id: "bench", source: "/bench", type: "bench.target.completed"},
      [:exact, :single, :multi]
    }
  end
]

IO.puts("scenario\troutes\tbuild_ms\titerations\tmean_us\tp50_us\tp95_us")

Enum.each(scenarios, fn {scenario, setup} ->
  Enum.each(sizes, fn size ->
    {routes, signal, expected_targets} = setup.(size)
    {build_us, router} = :timer.tc(fn -> Router.new!(routes) end)
    count = iterations.(size)

    for _iteration <- 1..min(count, 100) do
      {:ok, ^expected_targets} = Router.route(router, signal)
    end

    samples =
      for _iteration <- 1..count do
        start = System.monotonic_time(:nanosecond)
        {:ok, ^expected_targets} = Router.route(router, signal)
        System.monotonic_time(:nanosecond) - start
      end
      |> Enum.sort()

    mean_us = Enum.sum(samples) / count / 1_000
    p50_us = percentile.(samples, 0.50) / 1_000
    p95_us = percentile.(samples, 0.95) / 1_000

    IO.puts(
      Enum.join(
        [
          scenario,
          size,
          Float.round(build_us / 1_000, 3),
          count,
          Float.round(mean_us, 3),
          Float.round(p50_us, 3),
          Float.round(p95_us, 3)
        ],
        "\t"
      )
    )

    :erlang.garbage_collect()
  end)
end)
