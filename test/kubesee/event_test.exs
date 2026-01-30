defmodule Kubesee.EventTest do
  use ExUnit.Case

  alias Kubesee.Event

  describe "from_k8s_map/1" do
    test "creates event from K8s event map" do
      k8s_event = %{
        "apiVersion" => "v1",
        "kind" => "Event",
        "metadata" => %{
          "name" => "test-pod.abc123",
          "namespace" => "default",
          "uid" => "uid-123",
          "resourceVersion" => "12345",
          "creationTimestamp" => "2025-01-15T10:30:00Z"
        },
        "involvedObject" => %{
          "kind" => "Pod",
          "namespace" => "default",
          "name" => "test-pod",
          "uid" => "pod-uid-456",
          "apiVersion" => "v1",
          "resourceVersion" => "67890",
          "fieldPath" => "spec.containers{app}"
        },
        "reason" => "Created",
        "message" => "Pod created successfully",
        "type" => "Normal",
        "count" => 1,
        "firstTimestamp" => "2025-01-15T10:30:00Z",
        "lastTimestamp" => "2025-01-15T10:30:05Z",
        "source" => %{
          "component" => "kubelet",
          "host" => "node-1"
        }
      }

      event = Event.from_k8s_map(k8s_event)

      assert event.name == "test-pod.abc123"
      assert event.namespace == "default"
      assert event.uid == "uid-123"
      assert event.reason == "Created"
      assert event.message == "Pod created successfully"
      assert event.type == "Normal"
      assert event.count == 1
      assert event.involved_object.kind == "Pod"
      assert event.involved_object.name == "test-pod"
      assert event.source.component == "kubelet"
      assert event.source.host == "node-1"
    end

    test "handles missing optional fields" do
      k8s_event = %{
        "metadata" => %{
          "name" => "test-event",
          "namespace" => "default"
        },
        "involvedObject" => %{
          "kind" => "Pod",
          "name" => "test-pod"
        },
        "reason" => "Test",
        "message" => "Test message"
      }

      event = Event.from_k8s_map(k8s_event)

      assert event.name == "test-event"
      assert event.count == nil
      assert event.first_timestamp == nil
      assert event.source.component == nil
    end

    test "parses timestamps as DateTime" do
      k8s_event = %{
        "metadata" => %{"name" => "test", "namespace" => "default"},
        "involvedObject" => %{"kind" => "Pod", "name" => "pod"},
        "firstTimestamp" => "2025-01-15T10:30:00Z",
        "lastTimestamp" => "2025-01-15T10:30:05.123Z",
        "eventTime" => "2025-01-15T10:30:00.000000Z"
      }

      event = Event.from_k8s_map(k8s_event)

      assert %DateTime{} = event.first_timestamp
      assert event.first_timestamp.year == 2025
      assert event.first_timestamp.month == 1
      assert event.first_timestamp.day == 15
    end
  end

  describe "dedot/1" do
    test "replaces dots with underscores in labels" do
      event = %Event{
        labels: %{"app.kubernetes.io/name" => "nginx", "version" => "1.0"},
        annotations: %{},
        involved_object: %Event.ObjectReference{
          labels: %{"app.kubernetes.io/instance" => "prod"},
          annotations: %{}
        }
      }

      dedotted = Event.dedot(event)

      assert dedotted.labels["app_kubernetes_io/name"] == "nginx"
      assert dedotted.labels["version"] == "1.0"
      refute Map.has_key?(dedotted.labels, "app.kubernetes.io/name")
      assert dedotted.involved_object.labels["app_kubernetes_io/instance"] == "prod"
    end

    test "replaces dots in annotations" do
      event = %Event{
        labels: %{},
        annotations: %{"kubectl.kubernetes.io/last-applied" => "{}"},
        involved_object: %Event.ObjectReference{
          labels: %{},
          annotations: %{"prometheus.io/scrape" => "true"}
        }
      }

      dedotted = Event.dedot(event)

      assert dedotted.annotations["kubectl_kubernetes_io/last-applied"] == "{}"
      assert dedotted.involved_object.annotations["prometheus_io/scrape"] == "true"
    end

    test "handles empty maps" do
      event = %Event{
        labels: %{},
        annotations: %{},
        involved_object: %Event.ObjectReference{labels: %{}, annotations: %{}}
      }

      dedotted = Event.dedot(event)

      assert dedotted.labels == %{}
      assert dedotted.involved_object.labels == %{}
    end

    test "handles nil maps" do
      event = %Event{
        labels: nil,
        annotations: nil,
        involved_object: %Event.ObjectReference{labels: nil, annotations: nil}
      }

      dedotted = Event.dedot(event)

      assert dedotted.labels == nil
      assert dedotted.involved_object.labels == nil
    end
  end

  describe "get_timestamp_ms/1" do
    test "returns milliseconds from first_timestamp" do
      event = %Event{
        first_timestamp: ~U[2025-01-15 10:30:00.000Z],
        event_time: ~U[2025-01-15 10:00:00.000Z]
      }

      ms = Event.get_timestamp_ms(event)

      assert is_integer(ms)
      assert ms == 1_736_937_000_000
    end

    test "falls back to event_time when first_timestamp is nil" do
      event = %Event{
        first_timestamp: nil,
        event_time: ~U[2025-01-15 10:00:00.000Z]
      }

      ms = Event.get_timestamp_ms(event)

      assert ms == 1_736_935_200_000
    end

    test "returns 0 when both timestamps are nil" do
      event = %Event{first_timestamp: nil, event_time: nil}

      assert Event.get_timestamp_ms(event) == 0
    end
  end

  describe "get_timestamp_iso8601/1" do
    test "returns ISO8601 format with milliseconds" do
      event = %Event{first_timestamp: ~U[2025-01-15 10:30:00.123Z]}

      result = Event.get_timestamp_iso8601(event)

      assert result == "2025-01-15T10:30:00.123Z"
    end

    test "pads milliseconds to 3 digits" do
      event = %Event{first_timestamp: ~U[2025-01-15 10:30:00.000Z]}

      result = Event.get_timestamp_iso8601(event)

      assert result == "2025-01-15T10:30:00.000Z"
    end

    test "falls back to event_time" do
      event = %Event{
        first_timestamp: nil,
        event_time: ~U[2025-01-15 10:00:00.500Z]
      }

      result = Event.get_timestamp_iso8601(event)

      assert result == "2025-01-15T10:00:00.500Z"
    end

    test "returns empty string when no timestamp" do
      event = %Event{first_timestamp: nil, event_time: nil}

      assert Event.get_timestamp_iso8601(event) == ""
    end
  end

  describe "to_json/1" do
    test "serializes event to JSON" do
      event = %Event{
        message: "Test message",
        reason: "Created",
        type: "Normal",
        namespace: "default"
      }

      json = Event.to_json(event)

      assert is_binary(json)
      {:ok, decoded} = Jason.decode(json)
      assert decoded["message"] == "Test message"
      assert decoded["reason"] == "Created"
    end
  end

  describe "to_template_context/1" do
    test "returns map with PascalCase keys" do
      event = %Event{
        message: "Pod created",
        reason: "Created",
        type: "Normal",
        count: 1,
        namespace: "default",
        name: "test-event",
        uid: "uid-123",
        first_timestamp: ~U[2025-01-15 10:30:00.000Z],
        involved_object: %Event.ObjectReference{
          kind: "Pod",
          name: "test-pod",
          namespace: "default",
          labels: %{"app" => "nginx"}
        },
        source: %Event.Source{
          component: "kubelet",
          host: "node-1"
        }
      }

      ctx = Event.to_template_context(event)

      assert ctx["Message"] == "Pod created"
      assert ctx["Reason"] == "Created"
      assert ctx["Type"] == "Normal"
      assert ctx["Count"] == 1
      assert ctx["Namespace"] == "default"
      assert ctx["Name"] == "test-event"
      assert ctx["UID"] == "uid-123"
      assert ctx["InvolvedObject"]["Kind"] == "Pod"
      assert ctx["InvolvedObject"]["Name"] == "test-pod"
      assert ctx["InvolvedObject"]["Labels"]["app"] == "nginx"
      assert ctx["Source"]["Component"] == "kubelet"
      assert ctx["Source"]["Host"] == "node-1"
    end

    test "includes helper methods as callable functions" do
      event = %Event{
        first_timestamp: ~U[2025-01-15 10:30:00.123Z]
      }

      ctx = Event.to_template_context(event)

      assert is_function(ctx["GetTimestampMs"], 0)
      assert is_function(ctx["GetTimestampISO8601"], 0)
      assert ctx["GetTimestampMs"].() == 1_736_937_000_123
      assert ctx["GetTimestampISO8601"].() == "2025-01-15T10:30:00.123Z"
    end

    test "formats timestamps as ISO8601 strings" do
      event = %Event{
        first_timestamp: ~U[2025-01-15 10:30:00.000Z],
        last_timestamp: ~U[2025-01-15 10:30:05.500Z],
        event_time: ~U[2025-01-15 10:30:00.000Z]
      }

      ctx = Event.to_template_context(event)

      assert ctx["FirstTimestamp"] == "2025-01-15T10:30:00.000Z"
      assert ctx["LastTimestamp"] == "2025-01-15T10:30:05.500Z"
      assert ctx["EventTime"] == "2025-01-15T10:30:00.000Z"
    end

    test "handles nil involved_object fields" do
      event = %Event{
        involved_object: %Event.ObjectReference{
          kind: "Pod",
          name: "test",
          labels: nil,
          annotations: nil
        }
      }

      ctx = Event.to_template_context(event)

      assert ctx["InvolvedObject"]["Labels"] == %{}
      assert ctx["InvolvedObject"]["Annotations"] == %{}
    end
  end
end
