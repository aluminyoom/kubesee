defmodule Kubesee.Sinks.OpenSearchTest do
  use ExUnit.Case, async: true

  alias Kubesee.Event
  alias Kubesee.Sinks.OpenSearch

  setup do
    bypass = Bypass.open()

    event = %Event{
      uid: "abc-123-def",
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

    {:ok, bypass: bypass, event: event}
  end

  describe "start_link/1 and send/2" do
    test "indexes event to OpenSearch", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/kube-events/_doc", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["message"] == "Pod created"
        assert decoded["reason"] == "Created"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, ~s({"result":"created"}))
      end)

      config = %{
        "hosts" => ["http://localhost:#{bypass.port}"],
        "index" => "kube-events"
      }

      {:ok, sink} = OpenSearch.start_link(config)
      assert :ok = OpenSearch.send(sink, event)
      OpenSearch.close(sink)
    end

    test "uses event UID as document ID when useEventID is true", %{
      bypass: bypass,
      event: event
    } do
      Bypass.expect_once(bypass, "POST", "/kube-events/_doc/abc-123-def", fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, ~s({"result":"created"}))
      end)

      config = %{
        "hosts" => ["http://localhost:#{bypass.port}"],
        "index" => "kube-events",
        "useEventID" => true
      }

      {:ok, sink} = OpenSearch.start_link(config)
      assert :ok = OpenSearch.send(sink, event)
      OpenSearch.close(sink)
    end

    test "formats index name with date pattern from indexFormat", %{
      bypass: bypass,
      event: event
    } do
      now = DateTime.utc_now()
      expected_index = "kube-events-#{Calendar.strftime(now, "%Y-%m-%d")}"

      Bypass.expect_once(bypass, "POST", "/#{expected_index}/_doc", fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, ~s({"result":"created"}))
      end)

      config = %{
        "hosts" => ["http://localhost:#{bypass.port}"],
        "indexFormat" => "kube-events-{2006-01-02}"
      }

      {:ok, sink} = OpenSearch.start_link(config)
      assert :ok = OpenSearch.send(sink, event)
      OpenSearch.close(sink)
    end

    test "uses static index name when no indexFormat", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/my-static-index/_doc", fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, ~s({"result":"created"}))
      end)

      config = %{
        "hosts" => ["http://localhost:#{bypass.port}"],
        "index" => "my-static-index"
      }

      {:ok, sink} = OpenSearch.start_link(config)
      assert :ok = OpenSearch.send(sink, event)
      OpenSearch.close(sink)
    end

    test "applies deDot to event labels and annotations", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/kube-events/_doc", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert String.contains?(body, "app_kubernetes_io/name")
        refute String.contains?(body, "app.kubernetes.io/name")
        assert String.contains?(body, "note_example/value")
        refute String.contains?(body, "note.example/value")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, ~s({"result":"created"}))
      end)

      config = %{
        "hosts" => ["http://localhost:#{bypass.port}"],
        "index" => "kube-events",
        "deDot" => true
      }

      {:ok, sink} = OpenSearch.start_link(config)
      assert :ok = OpenSearch.send(sink, event)
      OpenSearch.close(sink)
    end

    test "uses custom layout when provided", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/kube-events/_doc", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["msg"] == "Pod created"
        assert decoded["kind"] == "Pod"
        assert Map.keys(decoded) == ["kind", "msg"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, ~s({"result":"created"}))
      end)

      config = %{
        "hosts" => ["http://localhost:#{bypass.port}"],
        "index" => "kube-events",
        "layout" => %{
          "msg" => "{{ .Message }}",
          "kind" => "{{ .InvolvedObject.Kind }}"
        }
      }

      {:ok, sink} = OpenSearch.start_link(config)
      assert :ok = OpenSearch.send(sink, event)
      OpenSearch.close(sink)
    end

    test "sends basic auth when username and password provided", %{
      bypass: bypass,
      event: event
    } do
      Bypass.expect_once(bypass, "POST", "/kube-events/_doc", fn conn ->
        [auth_header] = Plug.Conn.get_req_header(conn, "authorization")
        assert String.starts_with?(auth_header, "Basic ")
        decoded = Base.decode64!(String.trim_leading(auth_header, "Basic "))
        assert decoded == "elastic:secret123"

        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, ~s({"result":"created"}))
      end)

      config = %{
        "hosts" => ["http://localhost:#{bypass.port}"],
        "index" => "kube-events",
        "username" => "elastic",
        "password" => "secret123"
      }

      {:ok, sink} = OpenSearch.start_link(config)
      assert :ok = OpenSearch.send(sink, event)
      OpenSearch.close(sink)
    end

    test "returns error on server error response", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/kube-events/_doc", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, ~s({"error":"internal server error"}))
      end)

      config = %{
        "hosts" => ["http://localhost:#{bypass.port}"],
        "index" => "kube-events"
      }

      {:ok, sink} = OpenSearch.start_link(config)
      assert {:error, {:http_error, 500}} = OpenSearch.send(sink, event)
      OpenSearch.close(sink)
    end

    test "includes type in URL when type field is set", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/kube-events/_doc", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        params = Plug.Conn.fetch_query_params(conn).query_params
        assert params["type"] == "kube-event"

        decoded = Jason.decode!(body)
        assert decoded["message"] == "Pod created"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, ~s({"result":"created"}))
      end)

      config = %{
        "hosts" => ["http://localhost:#{bypass.port}"],
        "index" => "kube-events",
        "type" => "kube-event"
      }

      {:ok, sink} = OpenSearch.start_link(config)
      assert :ok = OpenSearch.send(sink, event)
      OpenSearch.close(sink)
    end
  end

  describe "format_index_name/2" do
    test "replaces Go date patterns in curly braces" do
      dt = ~U[2024-03-15 09:30:45Z]
      assert OpenSearch.format_index_name("kube-events-{2006-01-02}", dt) == "kube-events-2024-03-15"
    end

    test "handles year-month format" do
      dt = ~U[2024-03-15 09:30:45Z]
      assert OpenSearch.format_index_name("events-{2006.01}", dt) == "events-2024.03"
    end

    test "handles full datetime format" do
      dt = ~U[2024-03-15 09:30:45Z]

      assert OpenSearch.format_index_name("events-{2006-01-02-15-04-05}", dt) ==
               "events-2024-03-15-09-30-45"
    end

    test "returns pattern as-is when no curly braces" do
      dt = ~U[2024-03-15 09:30:45Z]
      assert OpenSearch.format_index_name("kube-events", dt) == "kube-events"
    end

    test "pads single-digit values" do
      dt = ~U[2024-01-05 03:04:05Z]
      assert OpenSearch.format_index_name("ev-{2006-01-02}", dt) == "ev-2024-01-05"
    end
  end

  describe "close/1" do
    test "stops the sink process" do
      {:ok, sink} =
        OpenSearch.start_link(%{
          "hosts" => ["http://localhost:9200"],
          "index" => "test"
        })

      assert Process.alive?(sink)
      OpenSearch.close(sink)
      refute Process.alive?(sink)
    end
  end
end
