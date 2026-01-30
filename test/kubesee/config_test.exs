defmodule Kubesee.ConfigTest do
  use ExUnit.Case

  alias Kubesee.Config

  @valid_minimal_config """
  route:
    routes:
      - match:
          - receiver: stdout
  receivers:
    - name: stdout
      stdout: {}
  """

  describe "parse/1" do
    test "parses valid minimal config" do
      assert {:ok, config} = Config.parse(@valid_minimal_config)
      assert config.log_level == "info"
      assert config.max_event_age_seconds == 5
      assert length(config.receivers) == 1
      assert hd(config.receivers).name == "stdout"
      assert hd(config.receivers).sink_type == :stdout
    end

    test "parses all top-level fields" do
      yaml = """
      logLevel: debug
      logFormat: json
      maxEventAgeSeconds: 60
      clusterName: my-cluster
      namespace: kube-system
      kubeQPS: 10.0
      kubeBurst: 20
      metricsNamePrefix: custom_
      omitLookup: true
      cacheSize: 2048
      route:
        routes:
          - match:
              - receiver: test
      receivers:
        - name: test
          stdout: {}
      """

      assert {:ok, config} = Config.parse(yaml)
      assert config.log_level == "debug"
      assert config.log_format == "json"
      assert config.max_event_age_seconds == 60
      assert config.cluster_name == "my-cluster"
      assert config.namespace == "kube-system"
      assert config.kube_qps == 10.0
      assert config.kube_burst == 20
      assert config.metrics_name_prefix == "custom_"
      assert config.omit_lookup == true
      assert config.cache_size == 2048
    end

    test "applies default values" do
      assert {:ok, config} = Config.parse(@valid_minimal_config)
      assert config.log_level == "info"
      assert config.log_format == "json"
      assert config.max_event_age_seconds == 5
      assert config.kube_qps == 5.0
      assert config.kube_burst == 10
      assert config.metrics_name_prefix == "kubesee_"
      assert config.omit_lookup == false
      assert config.cache_size == 1024
    end

    test "expands environment variables with ${VAR} syntax" do
      System.put_env("TEST_ENDPOINT", "https://example.com")

      yaml = """
      route:
        routes:
          - match:
              - receiver: test
      receivers:
        - name: test
          webhook:
            endpoint: ${TEST_ENDPOINT}
      """

      assert {:ok, config} = Config.parse(yaml)
      receiver = hd(config.receivers)
      assert receiver.sink_config["endpoint"] == "https://example.com"
    after
      System.delete_env("TEST_ENDPOINT")
    end

    test "expands environment variables with $VAR syntax" do
      System.put_env("TEST_KEY", "secret123")

      yaml = """
      route:
        routes:
          - match:
              - receiver: test
      receivers:
        - name: test
          webhook:
            endpoint: https://example.com
            headers:
              X-API-Key: $TEST_KEY
      """

      assert {:ok, config} = Config.parse(yaml)
      receiver = hd(config.receivers)
      assert receiver.sink_config["headers"]["X-API-Key"] == "secret123"
    after
      System.delete_env("TEST_KEY")
    end

    test "expands $$ to literal $" do
      yaml = """
      route:
        routes:
          - match:
              - receiver: test
      receivers:
        - name: test
          webhook:
            endpoint: https://example.com
            headers:
              X-Price: $$100
      """

      assert {:ok, config} = Config.parse(yaml)
      receiver = hd(config.receivers)
      assert receiver.sink_config["headers"]["X-Price"] == "$100"
    end

    test "unset env var expands to empty string" do
      System.delete_env("NONEXISTENT_VAR")

      yaml = """
      route:
        routes:
          - match:
              - receiver: test
      receivers:
        - name: test
          webhook:
            endpoint: https://example.com
            headers:
              X-Value: prefix${NONEXISTENT_VAR}suffix
      """

      assert {:ok, config} = Config.parse(yaml)
      receiver = hd(config.receivers)
      assert receiver.sink_config["headers"]["X-Value"] == "prefixsuffix"
    end

    test "returns error for invalid YAML" do
      yaml = """
      route: [invalid: yaml
      """

      assert {:error, msg} = Config.parse(yaml)
      assert msg =~ "YAML parse error"
    end

    test "returns error when receiver has no sink configuration" do
      yaml = """
      route:
        routes:
          - match:
              - receiver: test
      receivers:
        - name: test
      """

      assert {:error, msg} = Config.parse(yaml)
      assert msg =~ "no sink configuration"
    end

    test "returns error when receiver has multiple sink configurations" do
      yaml = """
      route:
        routes:
          - match:
              - receiver: test
      receivers:
        - name: test
          stdout: {}
          webhook:
            endpoint: https://example.com
      """

      assert {:error, msg} = Config.parse(yaml)
      assert msg =~ "multiple sink configurations"
    end

    test "returns error for unknown sink type" do
      yaml = """
      route:
        routes:
          - match:
              - receiver: test
      receivers:
        - name: test
          unknownsink:
            foo: bar
      """

      assert {:error, msg} = Config.parse(yaml)
      assert msg =~ "unknown sink type"
    end

    test "returns error when receiver missing name" do
      yaml = """
      route:
        routes:
          - match:
              - receiver: test
      receivers:
        - stdout: {}
      """

      assert {:error, msg} = Config.parse(yaml)
      assert msg =~ "missing required 'name' field"
    end

    test "returns error when both throttlePeriod and maxEventAgeSeconds are set" do
      yaml = """
      throttlePeriod: 10
      maxEventAgeSeconds: 20
      route:
        routes:
          - match:
              - receiver: test
      receivers:
        - name: test
          stdout: {}
      """

      assert {:error, msg} = Config.parse(yaml)
      assert msg =~ "cannot set both"
    end

    test "keeps all sink config keys as strings at all nesting levels" do
      yaml = """
      route:
        routes:
          - match:
              - receiver: test
      receivers:
        - name: test
          elasticsearch:
            hosts:
              - http://localhost:9200
            index: events
            tls:
              insecureSkipVerify: true
              serverName: es.local
      """

      assert {:ok, config} = Config.parse(yaml)
      receiver = hd(config.receivers)
      sink_config = receiver.sink_config

      assert is_binary(hd(Map.keys(sink_config)))
      assert sink_config["hosts"] == ["http://localhost:9200"]
      assert sink_config["tls"]["insecureSkipVerify"] == true
      assert is_binary(hd(Map.keys(sink_config["tls"])))
    end

    test "parses all supported sink types" do
      sinks = [
        {"stdout", "stdout: {}"},
        {"file", "file:\n        path: /tmp/events"},
        {"webhook", "webhook:\n        endpoint: https://example.com"},
        {"pipe", "pipe:\n        path: /dev/stdout"},
        {"elasticsearch", "elasticsearch:\n        hosts:\n          - http://localhost:9200"},
        {"opensearch", "opensearch:\n        hosts:\n          - http://localhost:9200"},
        {"kafka", "kafka:\n        brokers:\n          - localhost:9092\n        topic: events"},
        {"loki", "loki:\n        url: http://localhost:3100/loki/api/v1/push"},
        {"syslog", "syslog:\n        network: tcp\n        address: localhost:514"},
        {"kinesis", "kinesis:\n        streamName: events\n        region: us-east-1"},
        {"firehose", "firehose:\n        deliveryStreamName: events\n        region: us-east-1"},
        {"sqs", "sqs:\n        queueName: events\n        region: us-east-1"},
        {"sns", "sns:\n        topicARN: arn:aws:sns:us-east-1:123456789:events"},
        {"eventbridge", "eventbridge:\n        eventBusName: default\n        region: us-east-1"},
        {"opscenter", "opscenter:\n        region: us-east-1"},
        {"pubsub", "pubsub:\n        gcloud_project_id: my-project\n        topic: events"},
        {"bigquery",
         "bigquery:\n        project: my-project\n        dataset: events\n        table: k8s"},
        {"slack", "slack:\n        token: xxx\n        channel: \"#alerts\""},
        {"teams", "teams:\n        endpoint: https://outlook.office.com/webhook/xxx"},
        {"opsgenie", "opsgenie:\n        apiKey: xxx"}
      ]

      for {sink_name, sink_yaml} <- sinks do
        yaml = """
        route:
          routes:
            - match:
                - receiver: test
        receivers:
          - name: test
            #{sink_yaml}
        """

        assert {:ok, config} = Config.parse(yaml), "Failed to parse #{sink_name} sink"
        receiver = hd(config.receivers)
        assert receiver.sink_type == String.to_atom(sink_name), "Wrong sink type for #{sink_name}"
      end
    end

    test "parses route with drop and match rules" do
      yaml = """
      route:
        drop:
          - namespace: kube-system
          - type: Normal
        match:
          - receiver: warnings
            type: Warning
        routes:
          - match:
              - receiver: critical
                reason: OOMKilled
      receivers:
        - name: warnings
          stdout: {}
        - name: critical
          stdout: {}
      """

      assert {:ok, config} = Config.parse(yaml)
      assert length(config.route.drop) == 2
      assert length(config.route.match) == 1
      assert length(config.route.routes) == 1
    end

    test "parses leader election config" do
      yaml = """
      leaderElection:
        enabled: true
        leaderElectionID: kubesee-leader
      route:
        routes:
          - match:
              - receiver: test
      receivers:
        - name: test
          stdout: {}
      """

      assert {:ok, config} = Config.parse(yaml)
      assert config.leader_election.enabled == true
      assert config.leader_election.leader_election_id == "kubesee-leader"
    end
  end

  describe "expand_env/1" do
    test "handles mixed patterns" do
      System.put_env("VAR1", "one")
      System.put_env("VAR2", "two")

      input = "prefix $VAR1 middle ${VAR2} suffix"
      assert Config.expand_env(input) == "prefix one middle two suffix"
    after
      System.delete_env("VAR1")
      System.delete_env("VAR2")
    end
  end
end
