defmodule Kubesee.FactoryTest do
  use ExUnit.Case

  test "k8s_event/0 creates valid event structure" do
    event = Kubesee.Factory.k8s_event()

    assert event["apiVersion"] == "v1"
    assert event["kind"] == "Event"
    assert is_map(event["metadata"])
    assert is_binary(event["metadata"]["name"])
    assert is_map(event["involvedObject"])
    assert event["involvedObject"]["kind"] == "Pod"
  end

  test "k8s_event/1 accepts overrides" do
    event = Kubesee.Factory.k8s_event(%{"message" => "custom message"})

    assert event["message"] == "custom message"
    assert event["reason"] == "Created"
  end

  test "watch_event/0 creates ADDED event wrapper" do
    watch_event = Kubesee.Factory.watch_event()

    assert watch_event["type"] == "ADDED"
    assert is_map(watch_event["object"])
    assert watch_event["object"]["kind"] == "Event"
  end

  test "watch_event/2 accepts type and overrides" do
    watch_event = Kubesee.Factory.watch_event("MODIFIED", %{"reason" => "Updated"})

    assert watch_event["type"] == "MODIFIED"
    assert watch_event["object"]["reason"] == "Updated"
  end
end
