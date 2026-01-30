import Config

config :kubesee,
  drain_timeout: System.get_env("KUBESEE_DRAIN_TIMEOUT", "30000") |> String.to_integer()

if log_level = System.get_env("KUBESEE_LOG_LEVEL") do
  config :logger, level: String.to_atom(log_level)
end
