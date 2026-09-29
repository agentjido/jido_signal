ExUnit.start()

ExUnit.configure(exclude: [:skip, :property, :fuzz])

if Enum.any?(ExUnit.configuration()[:include], fn
     tag when tag in [:property, :fuzz] -> true
     {tag, value} when tag in [:property, :fuzz] -> value != false
     _ -> false
   end) do
  Code.require_file("property/support/report.exs", __DIR__)
  JidoSignalTest.Property.Report.prepare!()
  ExUnit.configure(formatters: [ExUnit.CLIFormatter, JidoSignalTest.Property.Report])
end
