# Prepare modules for Mimic
Enum.each(
  [
    :telemetry,
    System
  ],
  &Mimic.copy/1
)

ExUnit.start()

ExUnit.configure(capture_log: true, exclude: [:skip])
