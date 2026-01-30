defmodule Kubesee.RouteTest do
  use ExUnit.Case, async: true

  alias Kubesee.Event
  alias Kubesee.Route
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

  defp collect_sends(route, event) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    send_fn = fn receiver, ev ->
      Agent.update(agent, fn sends -> [{receiver, ev} | sends] end)
    end

    Route.process_event(route, event, send_fn)

    result = agent |> Agent.get(& &1) |> Enum.reverse()
    Agent.stop(agent)
    result
  end

  defp receivers_called(sends) do
    Enum.map(sends, fn {receiver, _ev} -> receiver end)
  end

  describe "process_event/3 with empty route" do
    test "empty route sends to no receivers" do
      route = %Route{}
      event = make_event()

      sends = collect_sends(route, event)

      assert sends == []
    end
  end

  describe "process_event/3 with basic match rules" do
    test "sends to receiver when match rule matches" do
      route = %Route{
        match: [%Rule{namespace: "kube-system", receiver: "osman"}]
      }

      event = make_event(%{namespace: "kube-system"})

      sends = collect_sends(route, event)

      assert receivers_called(sends) == ["osman"]
    end

    test "does not send when match rule does not match" do
      route = %Route{
        match: [%Rule{namespace: "kube-system", receiver: "osman"}]
      }

      event = make_event(%{namespace: "default"})

      sends = collect_sends(route, event)

      assert sends == []
    end

    test "sends to multiple receivers when multiple rules match" do
      route = %Route{
        match: [
          %Rule{namespace: "kube-system", receiver: "osman"},
          %Rule{receiver: "any"}
        ]
      }

      event = make_event(%{namespace: "kube-system"})

      sends = collect_sends(route, event)

      assert receivers_called(sends) == ["osman", "any"]
    end

    test "does not send when rule has no receiver" do
      route = %Route{
        match: [%Rule{namespace: "kube-system"}]
      }

      event = make_event(%{namespace: "kube-system"})

      sends = collect_sends(route, event)

      assert sends == []
    end
  end

  describe "process_event/3 with drop rules" do
    test "drops event when drop rule matches" do
      route = %Route{
        drop: [%Rule{namespace: "kube-system"}],
        match: [%Rule{receiver: "osman"}]
      }

      event = make_event(%{namespace: "kube-system"})

      sends = collect_sends(route, event)

      assert sends == []
    end

    test "processes event when drop rule does not match" do
      route = %Route{
        drop: [%Rule{namespace: "kube-system"}],
        match: [%Rule{receiver: "osman"}]
      }

      event = make_event(%{namespace: "default"})

      sends = collect_sends(route, event)

      assert receivers_called(sends) == ["osman"]
    end

    test "drops if any drop rule matches" do
      route = %Route{
        drop: [
          %Rule{namespace: "kube-system"},
          %Rule{namespace: "kube-public"}
        ],
        match: [%Rule{receiver: "osman"}]
      }

      event1 = make_event(%{namespace: "kube-system"})
      event2 = make_event(%{namespace: "kube-public"})

      assert collect_sends(route, event1) == []
      assert collect_sends(route, event2) == []
    end
  end

  describe "process_event/3 with sub-routes" do
    test "processes sub-routes when all match rules match" do
      route = %Route{
        match: [%Rule{namespace: "kube-system"}],
        routes: [
          %Route{
            match: [%Rule{receiver: "osman"}]
          }
        ]
      }

      event = make_event(%{namespace: "kube-system"})

      sends = collect_sends(route, event)

      assert receivers_called(sends) == ["osman"]
    end

    test "does not process sub-routes when match rule fails" do
      route = %Route{
        match: [%Rule{namespace: "kube-system"}],
        routes: [
          %Route{
            match: [%Rule{receiver: "osman"}]
          }
        ]
      }

      event = make_event(%{namespace: "default"})

      sends = collect_sends(route, event)

      assert sends == []
    end

    test "processes deeply nested sub-routes" do
      route = %Route{
        match: [%Rule{namespace: "kube-*"}],
        routes: [
          %Route{
            match: [%Rule{receiver: "osman"}],
            routes: [
              %Route{
                match: [%Rule{receiver: "any"}]
              }
            ]
          }
        ]
      }

      event = make_event(%{namespace: "kube-system"})

      sends = collect_sends(route, event)

      assert receivers_called(sends) == ["osman", "any"]
    end

    test "sub-route drop rules work independently" do
      route = %Route{
        match: [%Rule{namespace: "kube-*"}],
        routes: [
          %Route{
            match: [%Rule{receiver: "osman"}],
            routes: [
              %Route{
                drop: [%Rule{namespace: "kube-system"}],
                match: [%Rule{receiver: "any"}]
              }
            ]
          }
        ]
      }

      event = make_event(%{namespace: "kube-system"})

      sends = collect_sends(route, event)

      # osman is sent, but "any" is dropped by sub-route's drop rule
      assert receivers_called(sends) == ["osman"]
    end
  end

  describe "process_event/3 GH Issue 51 scenario" do
    # Test for the specific scenario from kubernetes-event-exporter issue #51
    test "selective matching with drop rule" do
      route = %Route{
        drop: [%Rule{type: "Normal"}],
        match: [%Rule{reason: "FailedCreatePodContainer", receiver: "elastic"}]
      }

      ev1 = make_event(%{type: "Warning", reason: "FailedCreatePodContainer"})
      ev2 = make_event(%{type: "Warning", reason: "FailedCreate"})

      sends1 = collect_sends(route, ev1)
      sends2 = collect_sends(route, ev2)

      # ev1 should be sent to elastic (matches reason)
      assert receivers_called(sends1) == ["elastic"]

      # ev2 should not be sent (doesn't match the reason rule)
      assert sends2 == []
    end
  end

  describe "process_event/3 with complex scenarios" do
    test "empty receiver string is treated as no receiver" do
      route = %Route{
        match: [%Rule{namespace: "kube-system", receiver: ""}]
      }

      event = make_event(%{namespace: "kube-system"})

      sends = collect_sends(route, event)

      assert sends == []
    end

    test "match rules with and without receivers" do
      route = %Route{
        match: [
          %Rule{namespace: "kube-system"},
          %Rule{type: "Warning", receiver: "alerts"}
        ]
      }

      event = make_event(%{namespace: "kube-system", type: "Warning"})

      sends = collect_sends(route, event)

      # Only the rule with receiver should send
      assert receivers_called(sends) == ["alerts"]
    end

    test "multiple sub-routes at same level" do
      route = %Route{
        match: [%Rule{namespace: "kube-system"}],
        routes: [
          %Route{match: [%Rule{receiver: "first"}]},
          %Route{match: [%Rule{receiver: "second"}]}
        ]
      }

      event = make_event(%{namespace: "kube-system"})

      sends = collect_sends(route, event)

      assert receivers_called(sends) == ["first", "second"]
    end

    test "sub-routes not processed if any match rule fails" do
      route = %Route{
        match: [
          %Rule{namespace: "kube-system"},
          %Rule{type: "Warning"}
        ],
        routes: [
          %Route{match: [%Rule{receiver: "sub"}]}
        ]
      }

      # Event matches namespace but not type
      event = make_event(%{namespace: "kube-system", type: "Normal"})

      sends = collect_sends(route, event)

      # Sub-routes not processed because not all match rules matched
      assert sends == []
    end

    test "sends to receiver even if sub-routes exist" do
      route = %Route{
        match: [%Rule{namespace: "kube-system", receiver: "parent"}],
        routes: [
          %Route{match: [%Rule{receiver: "child"}]}
        ]
      }

      event = make_event(%{namespace: "kube-system"})

      sends = collect_sends(route, event)

      assert receivers_called(sends) == ["parent", "child"]
    end
  end

  describe "process_event/3 returns :ok" do
    test "returns :ok regardless of processing result" do
      route = %Route{match: [%Rule{receiver: "test"}]}
      event = make_event()

      result = Route.process_event(route, event, fn _, _ -> :ignored end)

      assert result == :ok
    end
  end
end
