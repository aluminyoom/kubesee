defmodule Kubesee.Sinks.PipeTest do
  use ExUnit.Case, async: true

  alias Kubesee.Event
  alias Kubesee.Sinks.Pipe

  setup do
    event = %Event{
      message: "Pod created",
      reason: "Created",
      type: "Normal",
      namespace: "default",
      involved_object: %Event.ObjectReference{
        kind: "Pod",
        name: "test-pod",
        namespace: "default",
        labels: %{"app.kubernetes.io/name" => "test"}
      },
      source: %Event.Source{
        component: "kubelet",
        host: "node-1"
      }
    }

    test_id = :rand.uniform(1_000_000)
    path = "/tmp/kubesee-pipe-test-#{test_id}"

    on_exit(fn ->
      File.rm(path)
    end)

    {:ok, event: event, path: path}
  end

  describe "start_link/1 and send/2" do
    test "writes event as JSON to pipe/file path", %{event: event, path: path} do
      {:ok, sink} = Pipe.start_link(%{"path" => path})

      assert :ok = Pipe.send(sink, event)
      Pipe.close(sink)

      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      assert length(lines) == 1

      decoded = Jason.decode!(Enum.at(lines, 0))
      assert decoded["message"] == "Pod created"
    end

    test "writes multiple events as separate lines", %{event: event, path: path} do
      {:ok, sink} = Pipe.start_link(%{"path" => path})

      assert :ok = Pipe.send(sink, %{event | message: "Event 1"})
      assert :ok = Pipe.send(sink, %{event | message: "Event 2"})
      Pipe.close(sink)

      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      assert length(lines) == 2
    end

    test "applies deDot to event", %{event: event, path: path} do
      {:ok, sink} = Pipe.start_link(%{"path" => path, "deDot" => true})

      assert :ok = Pipe.send(sink, event)
      Pipe.close(sink)

      content = File.read!(path)
      assert String.contains?(content, "app_kubernetes_io/name")
      refute String.contains?(content, "app.kubernetes.io/name")
    end

    test "uses custom layout when provided", %{event: event, path: path} do
      layout = %{
        "msg" => "{{ .Message }}",
        "kind" => "{{ .InvolvedObject.Kind }}"
      }

      {:ok, sink} = Pipe.start_link(%{"path" => path, "layout" => layout})

      assert :ok = Pipe.send(sink, event)
      Pipe.close(sink)

      content = File.read!(path)
      decoded = Jason.decode!(String.trim(content))
      assert decoded["msg"] == "Pod created"
      assert decoded["kind"] == "Pod"
    end
  end

  describe "close/1" do
    test "closes pipe handle and stops process", %{event: _event, path: path} do
      {:ok, sink} = Pipe.start_link(%{"path" => path})
      assert Process.alive?(sink)

      Pipe.close(sink)
      refute Process.alive?(sink)
    end
  end
end
