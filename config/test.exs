import Config

config :kubesee,
  k8s_client: Kubesee.K8sClientMock

config :logger, level: :warning
