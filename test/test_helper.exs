require Logger
# Prepare modules for Mimic
Enum.each(
  [
    :telemetry,
    System
  ],
  &Mimic.copy/1
)

# Keep default logging volume low so async stress tests don't overload Logger
# and introduce timing-dependent failures in middleware timeouts.
#
# Tests that assert on debug output should use `capture_log/2` with `level: :debug`
# (or configure Logger level locally) rather than requiring a global debug level.
Logger.configure(level: :info)

ExUnit.start()

ExUnit.configure(capture_log: true, exclude: [:skip])
