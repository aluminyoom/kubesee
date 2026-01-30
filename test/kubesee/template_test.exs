defmodule Kubesee.TemplateTest do
  use ExUnit.Case, async: true

  alias Kubesee.Event
  alias Kubesee.Template

  defp make_event(attrs \\ %{}) do
    base = %Event{
      name: "test-event",
      namespace: "default",
      uid: "abc-123",
      reason: "Created",
      message: "Pod created successfully",
      type: "Normal",
      count: 1,
      first_timestamp: ~U[2024-01-15 10:30:00.123Z],
      involved_object: %Event.ObjectReference{
        kind: "Pod",
        namespace: "default",
        name: "my-pod",
        api_version: "v1",
        labels: %{"app" => "nginx", "env" => "prod"},
        annotations: %{"description" => "test pod"}
      },
      source: %Event.Source{
        component: "kubelet",
        host: "node-1"
      }
    }

    deep_merge(base, attrs)
  end

  defp deep_merge(%{} = base, %{} = override) do
    Map.merge(base, override, fn
      _key, %{} = base_val, %{} = override_val ->
        deep_merge(base_val, override_val)

      _key, _base_val, override_val ->
        override_val
    end)
  end

  describe "render/2 field access" do
    test "accesses top-level field" do
      event = make_event()
      assert {:ok, "default"} = Template.render("{{ .Namespace }}", event)
    end

    test "accesses nested field" do
      event = make_event()
      assert {:ok, "Pod"} = Template.render("{{ .InvolvedObject.Kind }}", event)
    end

    test "accesses deeply nested field" do
      event = make_event()
      assert {:ok, "my-pod"} = Template.render("{{ .InvolvedObject.Name }}", event)
    end

    test "returns empty string for missing field" do
      event = make_event()
      assert {:ok, ""} = Template.render("{{ .NonExistent }}", event)
    end

    test "returns entire context with just dot" do
      event = make_event()
      {:ok, result} = Template.render("{{ . }}", event)
      assert String.contains?(result, "Namespace")
    end

    test "combines literal text with templates" do
      event = make_event(%{namespace: "kube-system"})
      assert {:ok, "ns: kube-system"} = Template.render("ns: {{ .Namespace }}", event)
    end

    test "handles multiple template expressions" do
      event = make_event(%{namespace: "kube-system", type: "Warning"})
      assert {:ok, "kube-system/Warning"} = Template.render("{{ .Namespace }}/{{ .Type }}", event)
    end
  end

  describe "render/2 helper methods" do
    test "GetTimestampMs returns milliseconds" do
      event = make_event(%{first_timestamp: ~U[2024-01-15 10:30:00.123Z]})
      {:ok, result} = Template.render("{{ .GetTimestampMs }}", event)
      assert String.to_integer(result) > 0
    end

    test "GetTimestampISO8601 returns ISO8601 string" do
      event = make_event(%{first_timestamp: ~U[2024-01-15 10:30:00.123Z]})
      {:ok, result} = Template.render("{{ .GetTimestampISO8601 }}", event)
      assert result =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/
    end
  end

  describe "render/2 sprig functions" do
    test "toJson serializes to JSON" do
      event = make_event()
      {:ok, result} = Template.render("{{ toJson .InvolvedObject.Labels }}", event)
      assert result == ~s({"app":"nginx","env":"prod"})
    end

    test "toPrettyJson serializes to pretty JSON" do
      event = make_event(%{involved_object: %{labels: %{"app" => "nginx"}}})
      {:ok, result} = Template.render("{{ toPrettyJson .InvolvedObject.Labels }}", event)
      assert result =~ "{\n"
    end

    test "quote wraps in double quotes" do
      event = make_event(%{namespace: "default"})
      assert {:ok, ~s("default")} = Template.render("{{ quote .Namespace }}", event)
    end

    test "squote wraps in single quotes" do
      event = make_event(%{namespace: "default"})
      assert {:ok, "'default'"} = Template.render("{{ squote .Namespace }}", event)
    end

    test "upper converts to uppercase" do
      event = make_event(%{namespace: "default"})
      assert {:ok, "DEFAULT"} = Template.render("{{ upper .Namespace }}", event)
    end

    test "lower converts to lowercase" do
      event = make_event(%{namespace: "DEFAULT"})
      assert {:ok, "default"} = Template.render("{{ lower .Namespace }}", event)
    end

    test "trim removes whitespace" do
      event = make_event(%{message: "  hello  "})
      assert {:ok, "hello"} = Template.render("{{ trim .Message }}", event)
    end

    test "default returns default when value is nil" do
      event = make_event()
      assert {:ok, "fallback"} = Template.render("{{ default \"fallback\" .NonExistent }}", event)
    end

    test "default returns value when not nil" do
      event = make_event(%{namespace: "kube-system"})
      assert {:ok, "kube-system"} = Template.render("{{ default \"fallback\" .Namespace }}", event)
    end

    test "empty returns true for nil" do
      event = make_event()
      {:ok, result} = Template.render("{{ empty .NonExistent }}", event)
      assert result == "true"
    end

    test "empty returns false for non-empty value" do
      event = make_event(%{namespace: "default"})
      {:ok, result} = Template.render("{{ empty .Namespace }}", event)
      assert result == "false"
    end

    test "now returns current timestamp" do
      event = make_event()
      {:ok, result} = Template.render("{{ now }}", event)
      assert result =~ ~r/^\d{4}-\d{2}-\d{2}T/
    end
  end

  describe "render/2 index function" do
    test "index accesses map by key" do
      event = make_event(%{involved_object: %{labels: %{"app.kubernetes.io/name" => "myapp"}}})

      assert {:ok, "myapp"} =
               Template.render(
                 ~s({{ index .InvolvedObject.Labels "app.kubernetes.io/name" }}),
                 event
               )
    end

    test "index returns nil for missing key" do
      event = make_event()
      assert {:ok, ""} = Template.render(~s({{ index .InvolvedObject.Labels "missing" }}), event)
    end
  end

  describe "render/2 pipelines" do
    test "pipes value through single function" do
      event = make_event(%{namespace: "default"})
      assert {:ok, "DEFAULT"} = Template.render("{{ .Namespace | upper }}", event)
    end

    test "pipes value through multiple functions" do
      event = make_event(%{message: "  hello  "})
      assert {:ok, "HELLO"} = Template.render("{{ .Message | trim | upper }}", event)
    end

    test "pipes entire event to toJson" do
      event = make_event()
      {:ok, result} = Template.render("{{ . | toJson }}", event)
      decoded = Jason.decode!(result)
      assert decoded["Namespace"] == "default"
    end
  end

  describe "render/2 error handling" do
    test "returns error for unknown function" do
      event = make_event()

      assert {:error, "unknown function: unknownFunc"} =
               Template.render("{{ unknownFunc .Namespace }}", event)
    end
  end

  describe "convert_layout/2" do
    test "converts simple layout with templates" do
      event = make_event(%{namespace: "kube-system", type: "Warning"})

      layout = %{
        "namespace" => "{{ .Namespace }}",
        "type" => "{{ .Type }}",
        "static" => "unchanged"
      }

      {:ok, result} = Template.convert_layout(layout, event)

      assert result["namespace"] == "kube-system"
      assert result["type"] == "Warning"
      assert result["static"] == "unchanged"
    end

    test "converts nested layout" do
      event =
        make_event(%{
          namespace: "default",
          message: "test message",
          involved_object: %{kind: "Pod", name: "my-pod"}
        })

      layout = %{
        "details" => %{
          "message" => "{{ .Message }}",
          "kind" => "{{ .InvolvedObject.Kind }}",
          "name" => "{{ .InvolvedObject.Name }}"
        },
        "eventType" => "kube-event"
      }

      {:ok, result} = Template.convert_layout(layout, event)

      assert result["details"]["message"] == "test message"
      assert result["details"]["kind"] == "Pod"
      assert result["details"]["name"] == "my-pod"
      assert result["eventType"] == "kube-event"
    end

    test "converts layout with lists" do
      event = make_event(%{reason: "Created", involved_object: %{kind: "Pod"}})

      layout = %{
        "tags" => ["static", "{{ .Reason }}", "{{ .InvolvedObject.Kind }}"]
      }

      {:ok, result} = Template.convert_layout(layout, event)

      assert result["tags"] == ["static", "Created", "Pod"]
    end

    test "handles nil layout" do
      event = make_event()
      assert {:ok, nil} = Template.convert_layout(nil, event)
    end

    test "preserves non-string values" do
      event = make_event()

      layout = %{
        "count" => 42,
        "enabled" => true,
        "ratio" => 3.14
      }

      {:ok, result} = Template.convert_layout(layout, event)

      assert result["count"] == 42
      assert result["enabled"] == true
      assert result["ratio"] == 3.14
    end

    test "matches Go tmpl_test.go scenario" do
      event =
        make_event(%{
          namespace: "default",
          type: "Warning",
          message: ~s(Successfully pulled image "nginx:latest"),
          first_timestamp: ~U[2024-01-15 10:30:00.000Z],
          involved_object: %{kind: "Pod", name: "nginx-server-123abc-456def"}
        })

      layout = %{
        "details" => %{
          "message" => "{{ .Message }}",
          "kind" => "{{ .InvolvedObject.Kind }}",
          "name" => "{{ .InvolvedObject.Name }}",
          "namespace" => "{{ .Namespace }}",
          "type" => "{{ .Type }}",
          "tags" => ["sre", "ops"]
        },
        "eventType" => "kube-event",
        "region" => "us-west-2",
        "createdAt" => "{{ .GetTimestampMs }}"
      }

      {:ok, result} = Template.convert_layout(layout, event)

      assert result["eventType"] == "kube-event"
      assert result["region"] == "us-west-2"
      assert result["details"]["message"] == ~s(Successfully pulled image "nginx:latest")
      assert result["details"]["kind"] == "Pod"
      assert result["details"]["name"] == "nginx-server-123abc-456def"
      assert result["details"]["namespace"] == "default"
      assert result["details"]["type"] == "Warning"
      assert result["details"]["tags"] == ["sre", "ops"]
      assert String.to_integer(result["createdAt"]) > 0
    end
  end

  describe "render/2 real-world templates from config examples" do
    test "opsgenie message template" do
      event =
        make_event(%{
          reason: "FailedScheduling",
          namespace: "production",
          involved_object: %{name: "web-server-abc123"}
        })

      template =
        "Event {{ .Reason }} for {{ .InvolvedObject.Namespace }}/{{ .InvolvedObject.Name }} on K8s cluster"

      {:ok, result} = Template.render(template, event)

      assert result =~ "FailedScheduling"
      assert result =~ "web-server-abc123"
    end

    test "slack channel template with labels" do
      event = make_event(%{involved_object: %{labels: %{"owner" => "platform-team"}}})

      template = "@{{ index .InvolvedObject.Labels \"owner\" }}"
      {:ok, result} = Template.render(template, event)

      assert result == "@platform-team"
    end

    test "elasticsearch layout template" do
      base_event = make_event()

      event = %{
        base_event
        | message: "Container started",
          reason: "Started",
          type: "Normal",
          count: 3,
          namespace: "default",
          involved_object: %Event.ObjectReference{
            kind: "Pod",
            name: "nginx-pod",
            labels: %{"app" => "nginx"},
            annotations: %{}
          },
          source: %Event.Source{component: "kubelet", host: "node-1"}
      }

      layout = %{
        "region" => "us-west-2",
        "eventType" => "kubernetes-event",
        "createdAt" => "{{ .GetTimestampMs }}",
        "details" => %{
          "message" => "{{ .Message }}",
          "reason" => "{{ .Reason }}",
          "type" => "{{ .Type }}",
          "count" => "{{ .Count }}",
          "kind" => "{{ .InvolvedObject.Kind }}",
          "name" => "{{ .InvolvedObject.Name }}",
          "namespace" => "{{ .Namespace }}",
          "component" => "{{ .Source.Component }}",
          "host" => "{{ .Source.Host }}",
          "labels" => "{{ toJson .InvolvedObject.Labels }}"
        }
      }

      {:ok, result} = Template.convert_layout(layout, event)

      assert result["region"] == "us-west-2"
      assert result["eventType"] == "kubernetes-event"
      assert result["details"]["message"] == "Container started"
      assert result["details"]["reason"] == "Started"
      assert result["details"]["type"] == "Normal"
      assert result["details"]["count"] == "3"
      assert result["details"]["kind"] == "Pod"
      assert result["details"]["name"] == "nginx-pod"
      assert result["details"]["namespace"] == "default"
      assert result["details"]["component"] == "kubelet"
      assert result["details"]["host"] == "node-1"
      assert Jason.decode!(result["details"]["labels"]) == %{"app" => "nginx"}
    end
  end
end
