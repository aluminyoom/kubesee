defmodule Kubesee.Sinks.LokiTest do
  use ExUnit.Case, async: true

  alias Kubesee.Event
  alias Kubesee.Sinks.Loki

  setup do
    bypass = Bypass.open()

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

    {:ok, bypass: bypass, event: event}
  end

  describe "start_link/1 and send/2" do
    test "POSTs event to Loki push endpoint", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/loki/api/v1/push", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert %{"streams" => [stream]} = decoded
        assert %{"stream" => %{}, "values" => [[timestamp, log_line]]} = stream
        assert is_binary(timestamp)
        assert String.ends_with?(timestamp, "000000000")

        parsed_log = Jason.decode!(log_line)
        assert parsed_log["message"] == "Pod created"
        assert parsed_log["reason"] == "Created"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(204, "")
      end)

      config = %{"url" => endpoint_url(bypass, "/loki/api/v1/push")}
      {:ok, sink} = Loki.start_link(config)
      assert :ok = Loki.send(sink, event)
      Loki.close(sink)
    end

    test "includes stream labels", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/loki/api/v1/push", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert %{"streams" => [stream]} = decoded
        assert stream["stream"] == %{"app" => "kubesee", "env" => "test"}

        Plug.Conn.resp(conn, 204, "")
      end)

      config = %{
        "url" => endpoint_url(bypass, "/loki/api/v1/push"),
        "streamLabels" => %{"app" => "kubesee", "env" => "test"}
      }

      {:ok, sink} = Loki.start_link(config)
      assert :ok = Loki.send(sink, event)
      Loki.close(sink)
    end

    test "sends custom headers", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/loki/api/v1/push", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-scope-orgid") == ["tenant-1"]
        Plug.Conn.resp(conn, 204, "")
      end)

      config = %{
        "url" => endpoint_url(bypass, "/loki/api/v1/push"),
        "headers" => %{"X-Scope-OrgID" => "tenant-1"}
      }

      {:ok, sink} = Loki.start_link(config)
      assert :ok = Loki.send(sink, event)
      Loki.close(sink)
    end

    test "supports template headers with event data", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/loki/api/v1/push", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-namespace") == ["default"]
        assert Plug.Conn.get_req_header(conn, "x-reason") == ["Created"]
        Plug.Conn.resp(conn, 204, "")
      end)

      config = %{
        "url" => endpoint_url(bypass, "/loki/api/v1/push"),
        "headers" => %{
          "x-namespace" => "{{ .Namespace }}",
          "x-reason" => "{{ .Reason }}"
        }
      }

      {:ok, sink} = Loki.start_link(config)
      assert :ok = Loki.send(sink, event)
      Loki.close(sink)
    end

    test "falls back to raw header value on template error", %{bypass: bypass, event: event} do
      bad_template = "{{ .Namespace | unknownFunc }}"

      Bypass.expect_once(bypass, "POST", "/loki/api/v1/push", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-bad-template") == [bad_template]
        Plug.Conn.resp(conn, 204, "")
      end)

      config = %{
        "url" => endpoint_url(bypass, "/loki/api/v1/push"),
        "headers" => %{"x-bad-template" => bad_template}
      }

      {:ok, sink} = Loki.start_link(config)
      assert :ok = Loki.send(sink, event)
      Loki.close(sink)
    end

    test "uses custom layout when provided", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/loki/api/v1/push", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert %{"streams" => [stream]} = decoded
        [[_timestamp, log_line]] = stream["values"]

        parsed_log = Jason.decode!(log_line)
        assert parsed_log["msg"] == "Pod created"
        assert parsed_log["kind"] == "Pod"
        assert Map.keys(parsed_log) == ["kind", "msg"]

        Plug.Conn.resp(conn, 204, "")
      end)

      config = %{
        "url" => endpoint_url(bypass, "/loki/api/v1/push"),
        "layout" => %{
          "msg" => "{{ .Message }}",
          "kind" => "{{ .InvolvedObject.Kind }}"
        }
      }

      {:ok, sink} = Loki.start_link(config)
      assert :ok = Loki.send(sink, event)
      Loki.close(sink)
    end

    test "returns error on non-2xx response", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/loki/api/v1/push", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      config = %{"url" => endpoint_url(bypass, "/loki/api/v1/push")}
      {:ok, sink} = Loki.start_link(config)
      assert {:error, {:http_error, 500}} = Loki.send(sink, event)
      Loki.close(sink)
    end

    test "returns error on 400 response", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/loki/api/v1/push", fn conn ->
        Plug.Conn.resp(conn, 400, "Bad Request")
      end)

      config = %{"url" => endpoint_url(bypass, "/loki/api/v1/push")}
      {:ok, sink} = Loki.start_link(config)
      assert {:error, {:http_error, 400}} = Loki.send(sink, event)
      Loki.close(sink)
    end

    test "sets content-type to application/json", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/loki/api/v1/push", fn conn ->
        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
        Plug.Conn.resp(conn, 204, "")
      end)

      config = %{"url" => endpoint_url(bypass, "/loki/api/v1/push")}
      {:ok, sink} = Loki.start_link(config)
      assert :ok = Loki.send(sink, event)
      Loki.close(sink)
    end

    test "uses empty map for stream labels when not configured", %{
      bypass: bypass,
      event: event
    } do
      Bypass.expect_once(bypass, "POST", "/loki/api/v1/push", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert %{"streams" => [stream]} = decoded
        assert stream["stream"] == %{}

        Plug.Conn.resp(conn, 204, "")
      end)

      config = %{"url" => endpoint_url(bypass, "/loki/api/v1/push")}
      {:ok, sink} = Loki.start_link(config)
      assert :ok = Loki.send(sink, event)
      Loki.close(sink)
    end
  end

  describe "TLS configuration" do
    test "accepts TLS config", %{event: _event} do
      config = %{
        "url" => "https://loki.example.com/loki/api/v1/push",
        "tls" => %{
          "insecureSkipVerify" => true,
          "caFile" => "/path/to/ca.pem"
        }
      }

      {:ok, sink} = Loki.start_link(config)
      assert Process.alive?(sink)
      Loki.close(sink)
    end
  end

  describe "close/1" do
    test "stops the sink process" do
      config = %{"url" => "http://localhost:9999/loki/api/v1/push"}
      {:ok, sink} = Loki.start_link(config)
      assert Process.alive?(sink)

      Loki.close(sink)
      refute Process.alive?(sink)
    end
  end

  defp endpoint_url(bypass, path) do
    "http://localhost:#{bypass.port}#{path}"
  end
end
