defmodule Kubesee.Sinks.WebhookTest do
  use ExUnit.Case, async: true

  alias Kubesee.Event
  alias Kubesee.Sinks.Webhook

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
    test "POSTs event as JSON to endpoint", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/events", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["message"] == "Pod created"
        assert decoded["reason"] == "Created"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"status": "ok"}))
      end)

      {:ok, sink} = Webhook.start_link(%{"endpoint" => endpoint_url(bypass, "/events")})
      assert :ok = Webhook.send(sink, event)
      Webhook.close(sink)
    end

    test "sends custom headers", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/events", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-custom-header") == ["custom-value"]
        Plug.Conn.resp(conn, 200, "OK")
      end)

      config = %{
        "endpoint" => endpoint_url(bypass, "/events"),
        "headers" => %{"x-custom-header" => "custom-value"}
      }

      {:ok, sink} = Webhook.start_link(config)
      assert :ok = Webhook.send(sink, event)
      Webhook.close(sink)
    end

    test "supports template headers", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/events", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-namespace") == ["default"]
        assert Plug.Conn.get_req_header(conn, "x-reason") == ["Created"]
        Plug.Conn.resp(conn, 200, "OK")
      end)

      config = %{
        "endpoint" => endpoint_url(bypass, "/events"),
        "headers" => %{
          "x-namespace" => "{{ .Namespace }}",
          "x-reason" => "{{ .Reason }}"
        }
      }

      {:ok, sink} = Webhook.start_link(config)
      assert :ok = Webhook.send(sink, event)
      Webhook.close(sink)
    end

    test "uses custom layout when provided", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/events", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["msg"] == "Pod created"
        assert decoded["kind"] == "Pod"
        assert Map.keys(decoded) == ["kind", "msg"]
        Plug.Conn.resp(conn, 200, "OK")
      end)

      config = %{
        "endpoint" => endpoint_url(bypass, "/events"),
        "layout" => %{
          "msg" => "{{ .Message }}",
          "kind" => "{{ .InvolvedObject.Kind }}"
        }
      }

      {:ok, sink} = Webhook.start_link(config)
      assert :ok = Webhook.send(sink, event)
      Webhook.close(sink)
    end

    test "returns error on 4xx response", %{bypass: bypass, event: event} do
      Bypass.expect_once(bypass, "POST", "/events", fn conn ->
        Plug.Conn.resp(conn, 400, "Bad Request")
      end)

      {:ok, sink} = Webhook.start_link(%{"endpoint" => endpoint_url(bypass, "/events")})
      assert {:error, {:http_error, 400}} = Webhook.send(sink, event)
      Webhook.close(sink)
    end
  end

  describe "retry behavior" do
    test "retries on 503 and succeeds", %{bypass: bypass, event: event} do
      call_count = :counters.new(1, [])

      Bypass.expect(bypass, "POST", "/events", fn conn ->
        count = :counters.get(call_count, 1) + 1
        :counters.add(call_count, 1, 1)

        if count < 3 do
          Plug.Conn.resp(conn, 503, "Service Unavailable")
        else
          Plug.Conn.resp(conn, 200, "OK")
        end
      end)

      {:ok, sink} = Webhook.start_link(%{"endpoint" => endpoint_url(bypass, "/events")})
      assert :ok = Webhook.send(sink, event)
      assert :counters.get(call_count, 1) >= 2
      Webhook.close(sink)
    end

    test "does not retry on 400", %{bypass: bypass, event: event} do
      call_count = :counters.new(1, [])

      Bypass.expect(bypass, "POST", "/events", fn conn ->
        :counters.add(call_count, 1, 1)
        Plug.Conn.resp(conn, 400, "Bad Request")
      end)

      {:ok, sink} = Webhook.start_link(%{"endpoint" => endpoint_url(bypass, "/events")})
      assert {:error, {:http_error, 400}} = Webhook.send(sink, event)
      assert :counters.get(call_count, 1) == 1
      Webhook.close(sink)
    end

    test "retries on 429 (rate limit)", %{bypass: bypass, event: event} do
      call_count = :counters.new(1, [])

      Bypass.expect(bypass, "POST", "/events", fn conn ->
        count = :counters.get(call_count, 1) + 1
        :counters.add(call_count, 1, 1)

        if count < 2 do
          Plug.Conn.resp(conn, 429, "Too Many Requests")
        else
          Plug.Conn.resp(conn, 200, "OK")
        end
      end)

      {:ok, sink} = Webhook.start_link(%{"endpoint" => endpoint_url(bypass, "/events")})
      assert :ok = Webhook.send(sink, event)
      assert :counters.get(call_count, 1) >= 2
      Webhook.close(sink)
    end
  end

  describe "close/1" do
    test "stops the sink process", %{bypass: _bypass, event: _event} do
      {:ok, sink} = Webhook.start_link(%{"endpoint" => "http://example.com/events"})
      assert Process.alive?(sink)

      Webhook.close(sink)
      refute Process.alive?(sink)
    end
  end

  defp endpoint_url(bypass, path) do
    "http://localhost:#{bypass.port}#{path}"
  end
end
