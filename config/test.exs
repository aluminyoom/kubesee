import Config

config :kubesee,
  k8s_client: Kubesee.K8sClientMock,
  start_engine: false

config :logger, level: :warning
