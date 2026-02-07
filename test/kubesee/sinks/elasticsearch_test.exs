defmodule Kubesee.Sinks.ElasticsearchTest do
  use ExUnit.Case, async: true

  alias Kubesee.Event
  alias Kubesee.Sinks.Elasticsearch

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
        namespace: "default"
      },
      source: %Event.Source{
        component: "kubelet",
        host: "node-1"
      }
    }

    {:ok, bypass: bypass, event: event}
  end

  describe "basic indexing" do
    test "POSTs event as JSON to /_doc endpoint", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/kube-events/_doc", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["message"] == "Pod created"
        assert decoded["reason"] == "Created"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, ~s({"result": "created"}))
      end)

      config = %{
        "hosts" => [endpoint_url(bypass)],
        "index" => "kube-events"
      }

      {:ok, sink} = Elasticsearch.start_link(config)
      assert :ok = Elasticsearch.send(sink, event)
      Elasticsearch.close(sink)
    end
  end

  describe "useEventID" do
    test "PUTs with document ID when useEventID is true", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "PUT", "/kube-events/_doc/abc-123-def", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["message"] == "Pod created"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, ~s({"result": "created"}))
      end)

      config = %{
        "hosts" => [endpoint_url(bypass)],
        "index" => "kube-events",
        "useEventID" => true
      }

      {:ok, sink} = Elasticsearch.start_link(config)
      assert :ok = Elasticsearch.send(sink, event)
      Elasticsearch.close(sink)
    end
  end

  describe "indexFormat" do
    test "formats index name with date patterns", %{bypass: bypass, event: event} do
      now = DateTime.utc_now()
      year = String.pad_leading("#{now.year}", 4, "0")
      month = String.pad_leading("#{now.month}", 2, "0")
      day = String.pad_leading("#{now.day}", 2, "0")
      expected_index = "kube-events-#{year}-#{month}-#{day}"

      Bypass.expect_once(bypass, "POST", "/#{expected_index}/_doc", fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, ~s({"result": "created"}))
      end)

      config = %{
        "hosts" => [endpoint_url(bypass)],
        "index" => "kube-events",
        "indexFormat" => "kube-events-{2006-01-02}"
      }

      {:ok, sink} = Elasticsearch.start_link(config)
      assert :ok = Elasticsearch.send(sink, event)
      Elasticsearch.close(sink)
    end

    test "uses static index when indexFormat is not set", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/my-index/_doc", fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, ~s({"result": "created"}))
      end)

      config = %{
        "hosts" => [endpoint_url(bypass)],
        "index" => "my-index"
      }

      {:ok, sink} = Elasticsearch.start_link(config)
      assert :ok = Elasticsearch.send(sink, event)
      Elasticsearch.close(sink)
    end
  end

  describe "format_index_name/2" do
    test "replaces Go date format tokens" do
      dt = ~U[2024-03-15 09:30:45Z]

      assert Elasticsearch.format_index_name("kube-events-{2006-01-02}", dt) ==
               "kube-events-2024-03-15"
    end

    test "replaces time tokens" do
      dt = ~U[2024-03-15 09:30:45Z]

      assert Elasticsearch.format_index_name("events-{2006.01.02-15:04:05}", dt) ==
               "events-2024.03.15-09:30:45"
    end

    test "handles pattern without date blocks" do
      dt = ~U[2024-03-15 09:30:45Z]
      assert Elasticsearch.format_index_name("static-index", dt) == "static-index"
    end

    test "handles multiple date blocks" do
      dt = ~U[2024-03-15 09:30:45Z]

      assert Elasticsearch.format_index_name("events-{2006}-{01}-{02}", dt) ==
               "events-2024-03-15"
    end
  end

  describe "deDot" do
    test "replaces dots in keys when deDot is true", %{bypass: bypass} do
      event = %Event{
        message: "Pod created",
        reason: "Created",
        type: "Normal",
        namespace: "default",
        labels: %{"app.kubernetes.io/name" => "test"},
        annotations: %{"helm.sh/release" => "v1"},
        involved_object: %Event.ObjectReference{
          kind: "Pod",
          name: "test-pod",
          namespace: "default",
          labels: %{"app.kubernetes.io/name" => "test"},
          annotations: %{"meta.helm.sh/release" => "v1"}
        },
        source: %Event.Source{component: "kubelet", host: "node-1"}
      }

      Bypass.expect_once(bypass, "POST", "/kube-events/_doc", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["labels"]["app_kubernetes_io/name"] == "test"
        assert decoded["annotations"]["helm_sh/release"] == "v1"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, ~s({"result": "created"}))
      end)

      config = %{
        "hosts" => [endpoint_url(bypass)],
        "index" => "kube-events",
        "deDot" => true
      }

      {:ok, sink} = Elasticsearch.start_link(config)
      assert :ok = Elasticsearch.send(sink, event)
      Elasticsearch.close(sink)
    end
  end

  describe "custom layout" do
    test "uses layout template for serialization", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/kube-events/_doc", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["msg"] == "Pod created"
        assert decoded["kind"] == "Pod"
        assert Map.keys(decoded) == ["kind", "msg"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, ~s({"result": "created"}))
      end)

      config = %{
        "hosts" => [endpoint_url(bypass)],
        "index" => "kube-events",
        "layout" => %{
          "msg" => "{{ .Message }}",
          "kind" => "{{ .InvolvedObject.Kind }}"
        }
      }

      {:ok, sink} = Elasticsearch.start_link(config)
      assert :ok = Elasticsearch.send(sink, event)
      Elasticsearch.close(sink)
    end
  end

  describe "authentication" do
    test "sends basic auth header", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/kube-events/_doc", fn conn ->
        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        expected = "Basic " <> Base.encode64("elastic:changeme")
        assert auth == expected

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, ~s({"result": "created"}))
      end)

      config = %{
        "hosts" => [endpoint_url(bypass)],
        "index" => "kube-events",
        "username" => "elastic",
        "password" => "changeme"
      }

      {:ok, sink} = Elasticsearch.start_link(config)
      assert :ok = Elasticsearch.send(sink, event)
      Elasticsearch.close(sink)
    end

    test "sends apiKey auth header", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/kube-events/_doc", fn conn ->
        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == "ApiKey my-api-key-base64"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, ~s({"result": "created"}))
      end)

      config = %{
        "hosts" => [endpoint_url(bypass)],
        "index" => "kube-events",
        "apiKey" => "my-api-key-base64"
      }

      {:ok, sink} = Elasticsearch.start_link(config)
      assert :ok = Elasticsearch.send(sink, event)
      Elasticsearch.close(sink)
    end
  end

  describe "custom headers" do
    test "sends additional headers", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/kube-events/_doc", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-custom-header") == ["custom-value"]
        assert Plug.Conn.get_req_header(conn, "x-tenant") == ["tenant-1"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, ~s({"result": "created"}))
      end)

      config = %{
        "hosts" => [endpoint_url(bypass)],
        "index" => "kube-events",
        "headers" => %{
          "x-custom-header" => "custom-value",
          "x-tenant" => "tenant-1"
        }
      }

      {:ok, sink} = Elasticsearch.start_link(config)
      assert :ok = Elasticsearch.send(sink, event)
      Elasticsearch.close(sink)
    end
  end

  describe "error handling" do
    test "returns error on 4xx response", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/kube-events/_doc", fn conn ->
        Plug.Conn.resp(conn, 400, "Bad Request")
      end)

      config = %{
        "hosts" => [endpoint_url(bypass)],
        "index" => "kube-events"
      }

      {:ok, sink} = Elasticsearch.start_link(config)
      assert {:error, {:http_error, 400}} = Elasticsearch.send(sink, event)
      Elasticsearch.close(sink)
    end

    test "returns error on 5xx response", %{bypass: bypass, event: event} do
      Bypass.expect(bypass, "POST", "/kube-events/_doc", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      config = %{
        "hosts" => [endpoint_url(bypass)],
        "index" => "kube-events"
      }

      {:ok, sink} = Elasticsearch.start_link(config)
      assert {:error, {:http_error, 500}} = Elasticsearch.send(sink, event)
      Elasticsearch.close(sink)
    end
  end

  describe "type field" do
    test "includes type in URL path for ES < 8.0", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/kube-events/kube-event/_doc", fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, ~s({"result": "created"}))
      end)

      config = %{
        "hosts" => [endpoint_url(bypass)],
        "index" => "kube-events",
        "type" => "kube-event"
      }

      {:ok, sink} = Elasticsearch.start_link(config)
      assert :ok = Elasticsearch.send(sink, event)
      Elasticsearch.close(sink)
    end

    test "includes type in URL with useEventID", %{bypass: bypass, event: event} do
      Bypass.expect_once(
        bypass,
        "PUT",
        "/kube-events/kube-event/_doc/abc-123-def",
        fn conn ->
          {:ok, _body, conn} = Plug.Conn.read_body(conn)

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(201, ~s({"result": "created"}))
        end
      )

      config = %{
        "hosts" => [endpoint_url(bypass)],
        "index" => "kube-events",
        "type" => "kube-event",
        "useEventID" => true
      }

      {:ok, sink} = Elasticsearch.start_link(config)
      assert :ok = Elasticsearch.send(sink, event)
      Elasticsearch.close(sink)
    end
  end

  describe "close/1" do
    test "stops the sink process" do
      config = %{
        "hosts" => ["http://localhost:9200"],
        "index" => "kube-events"
      }

      {:ok, sink} = Elasticsearch.start_link(config)
      assert Process.alive?(sink)

      Elasticsearch.close(sink)
      refute Process.alive?(sink)
    end
  end

  defp endpoint_url(bypass) do
    "http://localhost:#{bypass.port}"
  end
end
