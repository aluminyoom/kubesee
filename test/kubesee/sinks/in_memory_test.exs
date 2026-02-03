defmodule Kubesee.Sinks.InMemoryTest do
  use ExUnit.Case, async: true

  alias Kubesee.Event
  alias Kubesee.Sinks.InMemory

  setup do
    event = %Event{
      message: "Pod created",
      reason: "Created",
      type: "Normal",
      namespace: "default",
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

  describe "start_link/1 and send/2" do
    test "stores events in memory", %{event: event} do
      {:ok, sink} = InMemory.start_link(%{})

      assert :ok = InMemory.send(sink, event)
      events = InMemory.get_events(sink)

      assert length(events) == 1
      assert Enum.at(events, 0).message == "Pod created"

      InMemory.close(sink)
    end

    test "stores multiple events in order", %{event: event} do
      {:ok, sink} = InMemory.start_link(%{})

      assert :ok = InMemory.send(sink, %{event | message: "Event 1"})
      assert :ok = InMemory.send(sink, %{event | message: "Event 2"})
      assert :ok = InMemory.send(sink, %{event | message: "Event 3"})

      events = InMemory.get_events(sink)
      messages = Enum.map(events, & &1.message)

      assert messages == ["Event 1", "Event 2", "Event 3"]

      InMemory.close(sink)
    end

    test "supports ref option for namespacing", %{event: event} do
      {:ok, sink1} = InMemory.start_link(%{"ref" => "sink-1"})
      {:ok, sink2} = InMemory.start_link(%{"ref" => "sink-2"})

      InMemory.send(sink1, %{event | message: "Event for sink 1"})
      InMemory.send(sink2, %{event | message: "Event for sink 2"})

      events1 = InMemory.get_events(sink1)
      events2 = InMemory.get_events(sink2)

      assert length(events1) == 1
      assert length(events2) == 1
      assert Enum.at(events1, 0).message == "Event for sink 1"
      assert Enum.at(events2, 0).message == "Event for sink 2"

      InMemory.close(sink1)
      InMemory.close(sink2)
    end
  end

  describe "get_events/1" do
    test "returns empty list when no events", %{event: _event} do
      {:ok, sink} = InMemory.start_link(%{})

      events = InMemory.get_events(sink)
      assert events == []

      InMemory.close(sink)
    end

    test "returns all stored events", %{event: event} do
      {:ok, sink} = InMemory.start_link(%{})

      Enum.each(1..5, fn i ->
        InMemory.send(sink, %{event | message: "Event #{i}"})
      end)

      events = InMemory.get_events(sink)
      assert length(events) == 5

      InMemory.close(sink)
    end
  end

  describe "clear/1" do
    test "clears all stored events", %{event: event} do
      {:ok, sink} = InMemory.start_link(%{})

      InMemory.send(sink, event)
      InMemory.send(sink, event)

      assert length(InMemory.get_events(sink)) == 2

      InMemory.clear(sink)

      assert InMemory.get_events(sink) == []

      InMemory.close(sink)
    end

    test "allows new events after clear", %{event: event} do
      {:ok, sink} = InMemory.start_link(%{})

      InMemory.send(sink, %{event | message: "Before clear"})
      InMemory.clear(sink)
      InMemory.send(sink, %{event | message: "After clear"})

      events = InMemory.get_events(sink)
      assert length(events) == 1
      assert Enum.at(events, 0).message == "After clear"

      InMemory.close(sink)
    end
  end

  describe "close/1" do
    test "stops the sink process", %{event: _event} do
      {:ok, sink} = InMemory.start_link(%{})
      assert Process.alive?(sink)

      InMemory.close(sink)
      refute Process.alive?(sink)
    end
  end
end
