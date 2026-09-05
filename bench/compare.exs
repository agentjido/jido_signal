Code.require_file("support/report.exs", __DIR__)

{opts, args, invalid} =
  OptionParser.parse(System.argv(), strict: [max_time_ratio: :float, max_memory_ratio: :float])

case {args, invalid} do
  {[before_path, after_path, output_path], []} ->
    before = before_path |> File.read!() |> Jason.decode!()
    after_report = after_path |> File.read!() |> Jason.decode!()
    comparison = JidoSignalBench.Report.compare!(before, after_report)
    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, comparison)
    IO.puts("Wrote #{output_path}")
    JidoSignalBench.Report.check_budgets!(before, after_report, opts)

  _ ->
    raise ArgumentError,
          "usage: mix run bench/compare.exs BEFORE.json AFTER.json COMPARISON.md [--max-time-ratio FLOAT] [--max-memory-ratio FLOAT]"
end
