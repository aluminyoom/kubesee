defmodule Kubesee.Sinks.StdoutTest do
  use ExUnit.Case, async: true

  alias Kubesee.Event
  alias Kubesee.Sinks.Stdout

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
        labels: %{"app.kubernetes.io/name" => "test"},
        annotations: %{"note.example/value" => "annotation"}
      },
      source: %Event.Source{
        component: "kubelet",
        host: "node-1"
      }
    }

    {:ok, string_io} = StringIO.open("")
    {:ok, event: event, string_io: string_io}
  end

  defp get_output(string_io) do
    StringIO.flush(string_io)
  end

  describe "start_link/1 and send/2" do
    test "outputs event as JSON to stdout", %{event: event, string_io: string_io} do
      {:ok, sink} = Stdout.start_link(%{"_device" => string_io})

      assert :ok = Stdout.send(sink, event)

      output = get_output(string_io)
      assert String.contains?(output, "Pod created")
      assert String.contains?(output, "\"reason\":\"Created\"")

      Stdout.close(sink)
    end

    test "applies deDot to event labels and annotations", %{event: event, string_io: string_io} do
      {:ok, sink} = Stdout.start_link(%{"deDot" => true, "_device" => string_io})

      assert :ok = Stdout.send(sink, event)

      output = get_output(string_io)
      assert String.contains?(output, "app_kubernetes_io/name")
      assert String.contains?(output, "note_example/value")
      refute String.contains?(output, "app.kubernetes.io/name")
      refute String.contains?(output, "note.example/value")

      Stdout.close(sink)
    end

    test "uses custom layout when provided", %{event: event, string_io: string_io} do
      layout = %{
        "msg" => "{{ .Message }}",
        "kind" => "{{ .InvolvedObject.Kind }}"
      }

      {:ok, sink} = Stdout.start_link(%{"layout" => layout, "_device" => string_io})

      assert :ok = Stdout.send(sink, event)

      output = get_output(string_io)
      decoded = Jason.decode!(String.trim(output))
      assert decoded["msg"] == "Pod created"
      assert decoded["kind"] == "Pod"

      Stdout.close(sink)
    end

    test "layout with deDot applies deDot before templating", %{event: event, string_io: string_io} do
      layout = %{
        "labels" => "{{ toJson .InvolvedObject.Labels }}"
      }

      {:ok, sink} =
        Stdout.start_link(%{"layout" => layout, "deDot" => true, "_device" => string_io})

      assert :ok = Stdout.send(sink, event)

      output = get_output(string_io)
      decoded = Jason.decode!(String.trim(output))
      labels_str = decoded["labels"]
      assert String.contains?(labels_str, "app_kubernetes_io/name")
      refute String.contains?(labels_str, "app.kubernetes.io/name")

      Stdout.close(sink)
    end

    test "outputs valid JSON that can be decoded", %{event: event, string_io: string_io} do
      {:ok, sink} = Stdout.start_link(%{"_device" => string_io})

      assert :ok = Stdout.send(sink, event)

      output = get_output(string_io)
      assert {:ok, _decoded} = Jason.decode(String.trim(output))

      Stdout.close(sink)
    end
  end

  describe "close/1" do
    test "stops the sink process", %{event: _event, string_io: _string_io} do
      {:ok, sink} = Stdout.start_link(%{})
      assert Process.alive?(sink)

      Stdout.close(sink)
      refute Process.alive?(sink)
    end
  end
end
