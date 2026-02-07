import Config

config :kubesee,
  k8s_client: Kubesee.K8sClientMock,
  kafka_client: Kubesee.KafkaClientMock,
  start_engine: false

config :logger, level: :warning
