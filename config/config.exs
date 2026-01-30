import Config

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :kubesee,
  k8s_client: Kubesee.K8sClient.Default

import_config "#{config_env()}.exs"
