defmodule Kubesee.Sinks.KafkaTest do
  use ExUnit.Case, async: false

  import Mox

  alias Kubesee.Event
  alias Kubesee.Sinks.Kafka

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    event = %Event{
      message: "Pod created",
      reason: "Created",
      type: "Normal",
      namespace: "default",
      uid: "test-uid-12345",
      involved_object: %Event.ObjectReference{
        kind: "Pod",
        name: "test-pod",
        namespace: "default"
      },
      source: %Event.Source{
        component: "kubelet",
        host: "node-1"
      }
    }

    {:ok, event: event}
  end

  defp start_kafka_sink(config, mock_module \\ Kubesee.KafkaClientMock) do
    stub(mock_module, :start_client, fn _brokers, _client_id, _config -> :ok end)
    stub(mock_module, :start_producer, fn _client_id, _topic, _config -> :ok end)
    stub(mock_module, :stop_client, fn _client_id -> :ok end)

    Kafka.start_link(config)
  end

  describe "start_link/1 and send/2" do
    test "produces event as JSON to kafka topic", %{event: event} do
      expect(Kubesee.KafkaClientMock, :start_client, fn brokers, client_id, _config ->
        assert brokers == [{~c"localhost", 9092}]
        assert client_id == :kubesee_kafka
        :ok
      end)

      expect(Kubesee.KafkaClientMock, :start_producer, fn client_id, topic, _config ->
        assert client_id == :kubesee_kafka
        assert topic == "kube-events"
        :ok
      end)

      expect(Kubesee.KafkaClientMock, :produce_sync, fn _client_id, topic, _partition, key, value ->
        assert topic == "kube-events"
        assert key == "test-uid-12345"
        decoded = Jason.decode!(value)
        assert decoded["message"] == "Pod created"
        assert decoded["reason"] == "Created"
        :ok
      end)

      expect(Kubesee.KafkaClientMock, :stop_client, fn _client_id -> :ok end)

      config = %{
        "topic" => "kube-events",
        "brokers" => ["localhost:9092"]
      }

      {:ok, sink} = Kafka.start_link(config)
      assert :ok = Kafka.send(sink, event)
      Kafka.close(sink)
    end

    test "uses event UID as partition key", %{event: event} do
      expect(Kubesee.KafkaClientMock, :produce_sync, fn _client_id, _topic, :hash, key, _value ->
        assert key == "test-uid-12345"
        :ok
      end)

      config = %{
        "topic" => "kube-events",
        "brokers" => ["localhost:9092"]
      }

      {:ok, sink} = start_kafka_sink(config)
      assert :ok = Kafka.send(sink, event)
      Kafka.close(sink)
    end

    test "uses empty string when event UID is nil", %{event: event} do
      event_no_uid = %{event | uid: nil}

      expect(Kubesee.KafkaClientMock, :produce_sync, fn _client_id, _topic, :hash, key, _value ->
        assert key == ""
        :ok
      end)

      config = %{
        "topic" => "kube-events",
        "brokers" => ["localhost:9092"]
      }

      {:ok, sink} = start_kafka_sink(config)
      assert :ok = Kafka.send(sink, event_no_uid)
      Kafka.close(sink)
    end

    test "uses custom layout for serialization", %{event: event} do
      expect(Kubesee.KafkaClientMock, :produce_sync, fn _client_id,
                                                        _topic,
                                                        _partition,
                                                        _key,
                                                        value ->
        decoded = Jason.decode!(value)
        assert decoded["msg"] == "Pod created"
        assert decoded["kind"] == "Pod"
        assert Map.keys(decoded) == ["kind", "msg"]
        :ok
      end)

      config = %{
        "topic" => "kube-events",
        "brokers" => ["localhost:9092"],
        "layout" => %{
          "msg" => "{{ .Message }}",
          "kind" => "{{ .InvolvedObject.Kind }}"
        }
      }

      {:ok, sink} = start_kafka_sink(config)
      assert :ok = Kafka.send(sink, event)
      Kafka.close(sink)
    end

    test "uses custom client ID", %{event: _event} do
      expect(Kubesee.KafkaClientMock, :start_client, fn _brokers, client_id, _config ->
        assert client_id == :my_custom_client
        :ok
      end)

      expect(Kubesee.KafkaClientMock, :start_producer, fn _client_id, _topic, _config -> :ok end)
      stub(Kubesee.KafkaClientMock, :stop_client, fn _client_id -> :ok end)

      config = %{
        "topic" => "kube-events",
        "brokers" => ["localhost:9092"],
        "clientId" => "my_custom_client"
      }

      {:ok, sink} = Kafka.start_link(config)
      Kafka.close(sink)
    end

    test "returns error on produce failure", %{event: event} do
      expect(Kubesee.KafkaClientMock, :produce_sync, fn _client_id,
                                                        _topic,
                                                        _partition,
                                                        _key,
                                                        _value ->
        {:error, :leader_not_available}
      end)

      config = %{
        "topic" => "kube-events",
        "brokers" => ["localhost:9092"]
      }

      {:ok, sink} = start_kafka_sink(config)
      assert {:error, :leader_not_available} = Kafka.send(sink, event)
      Kafka.close(sink)
    end
  end

  describe "parse_brokers/1" do
    test "parses host:port pairs" do
      assert Kafka.parse_brokers(["host1:9092", "host2:9093"]) == [
               {~c"host1", 9092},
               {~c"host2", 9093}
             ]
    end

    test "defaults port to 9092 when not specified" do
      assert Kafka.parse_brokers(["host1"]) == [{~c"host1", 9092}]
    end

    test "handles empty list" do
      assert Kafka.parse_brokers([]) == []
    end

    test "handles mixed formats" do
      assert Kafka.parse_brokers(["host1:9092", "host2"]) == [
               {~c"host1", 9092},
               {~c"host2", 9092}
             ]
    end
  end

  describe "build_client_config/1" do
    test "returns empty config with no optional settings" do
      config = %{"topic" => "test", "brokers" => ["localhost:9092"]}
      assert Kafka.build_client_config(config) == []
    end

    test "includes compression codec" do
      config = %{
        "topic" => "test",
        "brokers" => ["localhost:9092"],
        "compressionCodec" => "snappy"
      }

      result = Kafka.build_client_config(config)
      assert Keyword.get(result, :compression) == :snappy
    end

    test "skips compression for none" do
      config = %{
        "topic" => "test",
        "brokers" => ["localhost:9092"],
        "compressionCodec" => "none"
      }

      result = Kafka.build_client_config(config)
      assert Keyword.get(result, :compression) == nil
    end
  end

  describe "compression_codec/1" do
    test "maps snappy" do
      assert Kafka.compression_codec("snappy") == :snappy
    end

    test "maps gzip" do
      assert Kafka.compression_codec("gzip") == :gzip
    end

    test "maps lz4" do
      assert Kafka.compression_codec("lz4") == :lz4
    end

    test "maps zstd" do
      assert Kafka.compression_codec("zstd") == :zstd
    end

    test "defaults to no_compression for unknown" do
      assert Kafka.compression_codec("unknown") == :no_compression
    end
  end

  describe "TLS config" do
    test "builds SSL options with all fields" do
      tls_config = %{
        "enable" => true,
        "caFile" => "/path/to/ca.crt",
        "certFile" => "/path/to/cert.crt",
        "keyFile" => "/path/to/key.pem",
        "insecureSkipVerify" => false
      }

      result = Kafka.build_ssl_options(tls_config)
      assert Keyword.get(result, :cacertfile) == ~c"/path/to/ca.crt"
      assert Keyword.get(result, :certfile) == ~c"/path/to/cert.crt"
      assert Keyword.get(result, :keyfile) == ~c"/path/to/key.pem"
      assert Keyword.get(result, :verify) == :verify_peer
    end

    test "sets verify_none when insecureSkipVerify is true" do
      tls_config = %{
        "enable" => true,
        "insecureSkipVerify" => true
      }

      result = Kafka.build_ssl_options(tls_config)
      assert Keyword.get(result, :verify) == :verify_none
    end

    test "includes TLS in client config when enabled" do
      config = %{
        "topic" => "test",
        "brokers" => ["localhost:9092"],
        "tls" => %{
          "enable" => true,
          "caFile" => "/path/to/ca.crt"
        }
      }

      result = Kafka.build_client_config(config)
      ssl_opts = Keyword.get(result, :ssl)
      assert ssl_opts != nil
      assert Keyword.get(ssl_opts, :cacertfile) == ~c"/path/to/ca.crt"
    end

    test "does not include TLS when disabled" do
      config = %{
        "topic" => "test",
        "brokers" => ["localhost:9092"],
        "tls" => %{"enable" => false}
      }

      result = Kafka.build_client_config(config)
      assert Keyword.get(result, :ssl) == nil
    end
  end

  describe "SASL config" do
    test "builds plain SASL config" do
      config = %{
        "topic" => "test",
        "brokers" => ["localhost:9092"],
        "sasl" => %{
          "enable" => true,
          "username" => "user",
          "password" => "pass",
          "mechanism" => "plain"
        }
      }

      result = Kafka.build_client_config(config)
      assert Keyword.get(result, :sasl) == {:plain, "user", "pass"}
    end

    test "builds sha256 SASL config" do
      config = %{
        "topic" => "test",
        "brokers" => ["localhost:9092"],
        "sasl" => %{
          "enable" => true,
          "username" => "user",
          "password" => "pass",
          "mechanism" => "sha256"
        }
      }

      result = Kafka.build_client_config(config)
      assert Keyword.get(result, :sasl) == {:scram_sha_256, "user", "pass"}
    end

    test "builds sha512 SASL config" do
      config = %{
        "topic" => "test",
        "brokers" => ["localhost:9092"],
        "sasl" => %{
          "enable" => true,
          "username" => "user",
          "password" => "pass",
          "mechanism" => "sha512"
        }
      }

      result = Kafka.build_client_config(config)
      assert Keyword.get(result, :sasl) == {:scram_sha_512, "user", "pass"}
    end

    test "defaults to plain for unknown mechanism" do
      assert Kafka.sasl_mechanism("unknown") == :plain
    end

    test "does not include SASL when disabled" do
      config = %{
        "topic" => "test",
        "brokers" => ["localhost:9092"],
        "sasl" => %{"enable" => false}
      }

      result = Kafka.build_client_config(config)
      assert Keyword.get(result, :sasl) == nil
    end
  end

  describe "close/1" do
    test "stops the brod client on close" do
      expect(Kubesee.KafkaClientMock, :stop_client, fn client_id ->
        assert client_id == :kubesee_kafka
        :ok
      end)

      config = %{
        "topic" => "kube-events",
        "brokers" => ["localhost:9092"]
      }

      {:ok, sink} = start_kafka_sink(config)
      assert Process.alive?(sink)

      Kafka.close(sink)
      refute Process.alive?(sink)
    end
  end

  describe "init error handling" do
    test "returns error when client start fails" do
      expect(Kubesee.KafkaClientMock, :start_client, fn _brokers, _client_id, _config ->
        {:error, :connection_refused}
      end)

      config = %{
        "topic" => "kube-events",
        "brokers" => ["localhost:9092"]
      }

      Process.flag(:trap_exit, true)
      assert {:error, {:client_start_failed, :connection_refused}} = Kafka.start_link(config)
    end

    test "returns error when producer start fails and stops client" do
      expect(Kubesee.KafkaClientMock, :start_client, fn _brokers, _client_id, _config -> :ok end)

      expect(Kubesee.KafkaClientMock, :start_producer, fn _client_id, _topic, _config ->
        {:error, :topic_not_found}
      end)

      expect(Kubesee.KafkaClientMock, :stop_client, fn _client_id -> :ok end)

      config = %{
        "topic" => "kube-events",
        "brokers" => ["localhost:9092"]
      }

      Process.flag(:trap_exit, true)
      assert {:error, {:producer_start_failed, :topic_not_found}} = Kafka.start_link(config)
    end
  end
end
