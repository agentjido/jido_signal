Code.require_file("support/suite.exs", __DIR__)

{opts, args, invalid} =
  OptionParser.parse(System.argv(), strict: [profile: :string, output: :string])

if args != [] or invalid != [],
  do:
    raise(
      ArgumentError,
      "usage: mix run bench/run.exs --profile short|scale|smoke|candidates --output DIRECTORY"
    )

profile = Keyword.get(opts, :profile, "short")
output = Keyword.get(opts, :output, "bench/results/#{profile}")
report = JidoSignalBench.Suite.run(profile)
JidoSignalBench.Suite.write!(report, output)
IO.puts("Wrote #{output}/report.json and report.md")
