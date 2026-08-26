import Config

config :jido_signal,
  default_log_level: :info

config :logger, :default_formatter,
  metadata: [:bus_name, :signal_count, :signal_id, :signal_type, :subscription_id]
