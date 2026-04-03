import Config

log_level = System.get_env("LOG_LEVEL", "warning") |> String.to_existing_atom()

config :logger,
  level: log_level,
  handle_otp_reports: false,
  handle_sasl_reports: false

config :logger, :default_handler, false
