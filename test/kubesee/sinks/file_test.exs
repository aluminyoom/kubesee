defmodule Kubesee.Sinks.FileTest do
  use ExUnit.Case, async: true

  alias Kubesee.Event
  alias Kubesee.Sinks.File, as: FileSink

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
        annotations: %{}
      },
      source: %Event.Source{
        component: "kubelet",
        host: "node-1"
      }
    }

    test_id = :rand.uniform(1_000_000)
    path = "/tmp/kubesee-file-test-#{test_id}.log"

    on_exit(fn ->
      File.rm(path)

      Enum.each(1..10, fn n ->
        File.rm("#{path}.#{n}")
      end)
    end)

    {:ok, event: event, path: path}
  end

  describe "start_link/1 and send/2" do
    test "writes event as JSON lines to file", %{event: event, path: path} do
      {:ok, sink} = FileSink.start_link(%{"path" => path})

      assert :ok = FileSink.send(sink, event)
      FileSink.close(sink)

      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      assert length(lines) == 1

      decoded = Jason.decode!(Enum.at(lines, 0))
      assert decoded["message"] == "Pod created"
    end

    test "writes multiple events as separate JSON lines", %{event: event, path: path} do
      {:ok, sink} = FileSink.start_link(%{"path" => path})

      assert :ok = FileSink.send(sink, %{event | message: "Event 1"})
      assert :ok = FileSink.send(sink, %{event | message: "Event 2"})
      assert :ok = FileSink.send(sink, %{event | message: "Event 3"})
      FileSink.close(sink)

      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      assert length(lines) == 3

      messages = Enum.map(lines, fn line -> Jason.decode!(line)["message"] end)
      assert messages == ["Event 1", "Event 2", "Event 3"]
    end

    test "applies deDot to event", %{event: event, path: path} do
      {:ok, sink} = FileSink.start_link(%{"path" => path, "deDot" => true})

      assert :ok = FileSink.send(sink, event)
      FileSink.close(sink)

      content = File.read!(path)
      assert String.contains?(content, "app_kubernetes_io/name")
      refute String.contains?(content, "app.kubernetes.io/name")
    end

    test "uses custom layout when provided", %{event: event, path: path} do
      layout = %{
        "msg" => "{{ .Message }}",
        "kind" => "{{ .InvolvedObject.Kind }}"
      }

      {:ok, sink} = FileSink.start_link(%{"path" => path, "layout" => layout})

      assert :ok = FileSink.send(sink, event)
      FileSink.close(sink)

      content = File.read!(path)
      decoded = Jason.decode!(String.trim(content))
      assert decoded["msg"] == "Pod created"
      assert decoded["kind"] == "Pod"
    end
  end

  describe "file rotation" do
    test "rotates when file exceeds maxsize (MB)", %{event: event, path: path} do
      large_message = String.duplicate("x", 500_000)
      large_event = %{event | message: large_message}

      {:ok, sink} = FileSink.start_link(%{"path" => path, "maxsize" => 1})

      assert :ok = FileSink.send(sink, large_event)
      assert :ok = FileSink.send(sink, large_event)
      assert :ok = FileSink.send(sink, large_event)
      FileSink.close(sink)

      assert File.exists?("#{path}.1")
    end

    test "limits backup count to maxbackups", %{event: event, path: path} do
      large_message = String.duplicate("x", 400_000)
      large_event = %{event | message: large_message}

      {:ok, sink} = FileSink.start_link(%{"path" => path, "maxsize" => 1, "maxbackups" => 2})

      Enum.each(1..10, fn _i ->
        FileSink.send(sink, large_event)
      end)

      FileSink.close(sink)

      assert File.exists?("#{path}.1")
      assert File.exists?("#{path}.2")
      refute File.exists?("#{path}.3")
    end

    test "no rotation when maxsize is 0 (unlimited)", %{event: event, path: path} do
      {:ok, sink} = FileSink.start_link(%{"path" => path, "maxsize" => 0})

      Enum.each(1..10, fn _i ->
        FileSink.send(sink, event)
      end)

      FileSink.close(sink)

      refute File.exists?("#{path}.1")
    end
  end

  describe "close/1" do
    test "closes file handle and stops process", %{event: _event, path: path} do
      {:ok, sink} = FileSink.start_link(%{"path" => path})
      assert Process.alive?(sink)

      FileSink.close(sink)
      refute Process.alive?(sink)
    end
  end

  describe "error handling" do
    test "returns error for invalid path" do
      Process.flag(:trap_exit, true)
      result = FileSink.start_link(%{"path" => "/nonexistent/dir/file.log"})

      case result do
        {:error, _} ->
          assert true

        {:ok, pid} ->
          receive do
            {:EXIT, ^pid, reason} ->
              assert reason == :enoent
          after
            100 -> flunk("Expected process to exit")
          end
      end
    end
  end
end
