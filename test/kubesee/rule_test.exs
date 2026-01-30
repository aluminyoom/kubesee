defmodule Kubesee.RuleTest do
  use ExUnit.Case, async: true

  alias Kubesee.Event
  alias Kubesee.Rule

  defp make_event(attrs \\ %{}) do
    base = %Event{
      name: "test-event",
      namespace: "default",
      uid: "abc-123",
      reason: "Created",
      message: "Pod created successfully",
      type: "Normal",
      count: 1,
      involved_object: %Event.ObjectReference{
        kind: "Pod",
        namespace: "default",
        name: "my-pod",
        api_version: "v1",
        labels: %{},
        annotations: %{}
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

  describe "matches?/2 with empty rule" do
    test "empty rule matches any event" do
      rule = %Rule{}
      event = make_event()
      assert Rule.matches?(rule, event)
    end
  end

  describe "matches?/2 with basic fields" do
    test "matches namespace exactly" do
      rule = %Rule{namespace: "kube-system"}
      event = make_event(%{namespace: "kube-system"})
      assert Rule.matches?(rule, event)
    end

    test "does not match different namespace" do
      rule = %Rule{namespace: "kube-system"}
      event = make_event(%{namespace: "default"})
      refute Rule.matches?(rule, event)
    end

    test "matches namespace with regex" do
      rule = %Rule{namespace: "kube-*"}
      event1 = make_event(%{namespace: "kube-system"})
      event2 = make_event(%{namespace: "kube-public"})
      event3 = make_event(%{namespace: "default"})

      assert Rule.matches?(rule, event1)
      assert Rule.matches?(rule, event2)
      refute Rule.matches?(rule, event3)
    end

    test "matches type" do
      rule = %Rule{type: "Warning"}
      event = make_event(%{type: "Warning"})
      assert Rule.matches?(rule, event)
    end

    test "does not match different type" do
      rule = %Rule{type: "Warning"}
      event = make_event(%{type: "Normal"})
      refute Rule.matches?(rule, event)
    end

    test "matches type with regex alternation" do
      rule = %Rule{type: "Deployment|ReplicaSet"}
      event1 = make_event(%{type: "Deployment"})
      event2 = make_event(%{type: "ReplicaSet"})
      event3 = make_event(%{type: "Pod"})

      assert Rule.matches?(rule, event1)
      assert Rule.matches?(rule, event2)
      refute Rule.matches?(rule, event3)
    end

    test "matches reason" do
      rule = %Rule{reason: "FailedScheduling"}
      event = make_event(%{reason: "FailedScheduling"})
      assert Rule.matches?(rule, event)
    end

    test "matches message with regex" do
      rule = %Rule{message: "pulled.*nginx.*"}
      event = make_event(%{message: "Successfully pulled image \"nginx:latest\""})
      assert Rule.matches?(rule, event)
    end

    test "does not match different message" do
      rule = %Rule{message: "pulled.*nginx.*"}
      event = make_event(%{message: "Pod created successfully"})
      refute Rule.matches?(rule, event)
    end
  end

  describe "matches?/2 with involved_object fields" do
    test "matches kind" do
      rule = %Rule{kind: "Pod"}
      event = make_event(%{involved_object: %{kind: "Pod"}})
      assert Rule.matches?(rule, event)
    end

    test "matches kind with regex" do
      rule = %Rule{kind: "Pod|Deployment|ReplicaSet"}
      event1 = make_event(%{involved_object: %{kind: "Pod"}})
      event2 = make_event(%{involved_object: %{kind: "Deployment"}})
      event3 = make_event(%{involved_object: %{kind: "Service"}})

      assert Rule.matches?(rule, event1)
      assert Rule.matches?(rule, event2)
      refute Rule.matches?(rule, event3)
    end

    test "matches api_version" do
      rule = %Rule{api_version: "apps/v1"}
      event = make_event(%{involved_object: %{api_version: "apps/v1"}})
      assert Rule.matches?(rule, event)
    end
  end

  describe "matches?/2 with source fields" do
    test "matches component" do
      rule = %Rule{component: "kubelet"}
      event = make_event(%{source: %{component: "kubelet"}})
      assert Rule.matches?(rule, event)
    end

    test "does not match different component" do
      rule = %Rule{component: "scheduler"}
      event = make_event(%{source: %{component: "kubelet"}})
      refute Rule.matches?(rule, event)
    end

    test "matches host" do
      rule = %Rule{host: "node-1"}
      event = make_event(%{source: %{host: "node-1"}})
      assert Rule.matches?(rule, event)
    end
  end

  describe "matches?/2 with labels" do
    test "matches single label exactly" do
      rule = %Rule{labels: %{"env" => "prod"}}
      event = make_event(%{involved_object: %{labels: %{"env" => "prod"}}})
      assert Rule.matches?(rule, event)
    end

    test "does not match when label value differs" do
      rule = %Rule{labels: %{"env" => "prod"}}
      event = make_event(%{involved_object: %{labels: %{"env" => "lab"}}})
      refute Rule.matches?(rule, event)
    end

    test "matches label with regex" do
      rule = %Rule{labels: %{"version" => "alpha"}}
      event = make_event(%{involved_object: %{labels: %{"version" => "alpha-123"}}})
      assert Rule.matches?(rule, event)
    end

    test "matches multiple labels (all must match)" do
      rule = %Rule{labels: %{"env" => "prod", "version" => "beta"}}
      event = make_event(%{involved_object: %{labels: %{"env" => "prod", "version" => "beta"}}})
      assert Rule.matches?(rule, event)
    end

    test "does not match when one label value differs" do
      rule = %Rule{labels: %{"env" => "prod", "version" => "beta"}}
      event = make_event(%{involved_object: %{labels: %{"env" => "prod", "version" => "alpha"}}})
      refute Rule.matches?(rule, event)
    end

    test "does not match when required label is missing" do
      rule = %Rule{labels: %{"env" => "prod", "version" => "beta"}}
      event = make_event(%{involved_object: %{labels: %{"age" => "very-old", "version" => "beta"}}})
      refute Rule.matches?(rule, event)
    end

    test "empty labels rule matches any labels" do
      rule = %Rule{labels: %{}}
      event = make_event(%{involved_object: %{labels: %{"env" => "prod"}}})
      assert Rule.matches?(rule, event)
    end

    test "nil labels rule matches any labels" do
      rule = %Rule{labels: nil}
      event = make_event(%{involved_object: %{labels: %{"env" => "prod"}}})
      assert Rule.matches?(rule, event)
    end
  end

  describe "matches?/2 with annotations" do
    test "matches single annotation with regex" do
      rule = %Rule{annotations: %{"name" => "sou*"}}

      event =
        make_event(%{
          involved_object: %{annotations: %{"name" => "source", "service" => "event-exporter"}}
        })

      assert Rule.matches?(rule, event)
    end

    test "does not match when annotation pattern fails" do
      rule = %Rule{annotations: %{"name" => "test*"}}
      event = make_event(%{involved_object: %{annotations: %{"name" => "source"}}})
      refute Rule.matches?(rule, event)
    end

    test "matches multiple annotations" do
      rule = %Rule{annotations: %{"name" => "sou.*", "service" => "event*"}}

      event =
        make_event(%{
          involved_object: %{annotations: %{"name" => "source", "service" => "event-exporter"}}
        })

      assert Rule.matches?(rule, event)
    end

    test "does not match when required annotation is missing" do
      rule = %Rule{annotations: %{"name" => "sou*", "service" => "event*"}}
      event = make_event(%{involved_object: %{annotations: %{"service" => "event-exporter"}}})
      refute Rule.matches?(rule, event)
    end
  end

  describe "matches?/2 with min_count" do
    test "matches when count >= min_count" do
      rule = %Rule{min_count: 5}
      event = make_event(%{count: 10})
      assert Rule.matches?(rule, event)
    end

    test "matches when count equals min_count" do
      rule = %Rule{min_count: 5}
      event = make_event(%{count: 5})
      assert Rule.matches?(rule, event)
    end

    test "does not match when count < min_count" do
      rule = %Rule{min_count: 30}
      event = make_event(%{count: 5})
      refute Rule.matches?(rule, event)
    end

    test "nil min_count matches any count" do
      rule = %Rule{min_count: nil}
      event = make_event(%{count: 1})
      assert Rule.matches?(rule, event)
    end

    test "min_count 0 matches any count" do
      rule = %Rule{min_count: 0}
      event = make_event(%{count: 1})
      assert Rule.matches?(rule, event)
    end
  end

  describe "matches?/2 with complex rules" do
    test "complex rule with multiple conditions - all match" do
      rule = %Rule{
        namespace: "kube-system",
        kind: "Pod",
        labels: %{"env" => "prod", "version" => "alpha"},
        annotations: %{"service" => "event*"}
      }

      event =
        make_event(%{
          namespace: "kube-system",
          involved_object: %{
            kind: "Pod",
            labels: %{"env" => "prod", "version" => "alpha"},
            annotations: %{"service" => "event-exporter"}
          }
        })

      assert Rule.matches?(rule, event)
    end

    test "complex rule - one basic field fails" do
      rule = %Rule{
        namespace: "kube-system",
        type: "Warning",
        labels: %{"env" => "prod", "version" => "alpha"}
      }

      event =
        make_event(%{
          namespace: "default",
          type: "Warning",
          involved_object: %{labels: %{"env" => "prod", "version" => "alpha"}}
        })

      refute Rule.matches?(rule, event)
    end

    test "complex rule with regex patterns" do
      rule = %Rule{
        namespace: "kube*",
        kind: "Po*",
        labels: %{"env" => "prod", "version" => "alpha|beta"}
      }

      event =
        make_event(%{
          namespace: "kube-system",
          involved_object: %{
            kind: "Pod",
            labels: %{"env" => "prod", "version" => "alpha"}
          }
        })

      assert Rule.matches?(rule, event)
    end

    test "complex rule - regex does not match" do
      rule = %Rule{
        namespace: "kube*",
        type: "Deployment|ReplicaSet",
        labels: %{"env" => "prod", "version" => "alpha|beta"}
      }

      event =
        make_event(%{
          namespace: "kube-system",
          type: "Pod",
          involved_object: %{labels: %{"env" => "prod", "version" => "alpha"}}
        })

      refute Rule.matches?(rule, event)
    end

    test "complex rule - annotations do not match" do
      rule = %Rule{
        namespace: "kube-system",
        kind: "Pod",
        labels: %{"env" => "prod", "version" => "alpha"},
        annotations: %{"name" => "test*"}
      }

      event =
        make_event(%{
          namespace: "kube-system",
          involved_object: %{
            kind: "Pod",
            labels: %{"env" => "prod", "version" => "alpha"},
            annotations: %{"service" => "event*"}
          }
        })

      refute Rule.matches?(rule, event)
    end

    test "message regex with complex pattern" do
      rule = %Rule{
        type: "Pod",
        message: "pulled.*nginx.*"
      }

      event =
        make_event(%{
          type: "Pod",
          message: "Successfully pulled image \"nginx:latest\""
        })

      assert Rule.matches?(rule, event)
    end

    test "full complex scenario with count" do
      rule = %Rule{
        type: "Pod",
        message: "pulled.*nginx.*",
        min_count: 30
      }

      event =
        make_event(%{
          type: "Pod",
          message: "Successfully pulled image \"nginx:latest\"",
          count: 5
        })

      refute Rule.matches?(rule, event)
    end
  end

  describe "matches?/2 with nil values in event" do
    test "handles nil message in event" do
      rule = %Rule{message: "test"}
      event = make_event(%{message: nil})
      refute Rule.matches?(rule, event)
    end

    test "handles nil source" do
      rule = %Rule{component: "kubelet"}

      event = %Event{
        namespace: "default",
        involved_object: %Event.ObjectReference{},
        source: nil
      }

      refute Rule.matches?(rule, event)
    end

    test "handles nil involved_object labels" do
      rule = %Rule{labels: %{"env" => "prod"}}
      event = make_event(%{involved_object: %{labels: nil}})
      refute Rule.matches?(rule, event)
    end
  end
end
