defmodule Kubesee.Sinks.SyslogTest do
  use ExUnit.Case, async: true

  alias Kubesee.Event
  alias Kubesee.Sinks.Syslog

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

    {:ok, event: event}
  end

  describe "TCP mode" do
    setup do
      {:ok, listen_socket} =
        :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}, {:packet, :line}])

      {:ok, port} = :inet.port(listen_socket)

      on_exit(fn ->
        :gen_tcp.close(listen_socket)
      end)

      {:ok, listen_socket: listen_socket, port: port}
    end

    test "connects and sends event over TCP", %{
      event: event,
      listen_socket: listen_socket,
      port: port
    } do
      config = %{
        "network" => "tcp",
        "address" => "127.0.0.1:#{port}",
        "tag" => "k8s.event"
      }

      {:ok, sink} = Syslog.start_link(config)
      {:ok, server_socket} = :gen_tcp.accept(listen_socket, 5000)

      assert :ok = Syslog.send(sink, event)

      {:ok, data} = :gen_tcp.recv(server_socket, 0, 5000)

      assert String.starts_with?(data, "<134>k8s.event: ")
      json_part = data |> String.trim_leading("<134>k8s.event: ") |> String.trim()
      decoded = Jason.decode!(json_part)
      assert decoded["message"] == "Pod created"
      assert decoded["reason"] == "Created"

      :gen_tcp.close(server_socket)
      Syslog.close(sink)
    end

    test "sends multiple events over TCP", %{
      event: event,
      listen_socket: listen_socket,
      port: port
    } do
      config = %{
        "network" => "tcp",
        "address" => "127.0.0.1:#{port}",
        "tag" => "test.multi"
      }

      {:ok, sink} = Syslog.start_link(config)
      {:ok, server_socket} = :gen_tcp.accept(listen_socket, 5000)

      assert :ok = Syslog.send(sink, %{event | message: "Event 1"})
      assert :ok = Syslog.send(sink, %{event | message: "Event 2"})

      {:ok, line1} = :gen_tcp.recv(server_socket, 0, 5000)
      {:ok, line2} = :gen_tcp.recv(server_socket, 0, 5000)

      json1 = line1 |> String.trim_leading("<134>test.multi: ") |> String.trim()
      json2 = line2 |> String.trim_leading("<134>test.multi: ") |> String.trim()

      assert Jason.decode!(json1)["message"] == "Event 1"
      assert Jason.decode!(json2)["message"] == "Event 2"

      :gen_tcp.close(server_socket)
      Syslog.close(sink)
    end
  end

  describe "UDP mode" do
    setup do
      {:ok, udp_socket} = :gen_udp.open(0, [:binary, {:active, false}])
      {:ok, port} = :inet.port(udp_socket)

      on_exit(fn ->
        :gen_udp.close(udp_socket)
      end)

      {:ok, udp_socket: udp_socket, port: port}
    end

    test "connects and sends event over UDP", %{
      event: event,
      udp_socket: udp_socket,
      port: port
    } do
      config = %{
        "network" => "udp",
        "address" => "127.0.0.1:#{port}",
        "tag" => "k8s.event"
      }

      {:ok, sink} = Syslog.start_link(config)
      assert :ok = Syslog.send(sink, event)

      {:ok, {_addr, _recv_port, data}} = :gen_udp.recv(udp_socket, 0, 5000)

      assert String.starts_with?(data, "<134>k8s.event: ")
      json_part = data |> String.trim_leading("<134>k8s.event: ") |> String.trim()
      decoded = Jason.decode!(json_part)
      assert decoded["message"] == "Pod created"

      Syslog.close(sink)
    end

    test "sends multiple events over UDP", %{
      event: event,
      udp_socket: udp_socket,
      port: port
    } do
      config = %{
        "network" => "udp",
        "address" => "127.0.0.1:#{port}",
        "tag" => "udp.multi"
      }

      {:ok, sink} = Syslog.start_link(config)

      assert :ok = Syslog.send(sink, %{event | message: "UDP Event 1"})
      assert :ok = Syslog.send(sink, %{event | message: "UDP Event 2"})

      {:ok, {_addr, _port, data1}} = :gen_udp.recv(udp_socket, 0, 5000)
      {:ok, {_addr2, _port2, data2}} = :gen_udp.recv(udp_socket, 0, 5000)

      json1 = data1 |> String.trim_leading("<134>udp.multi: ") |> String.trim()
      json2 = data2 |> String.trim_leading("<134>udp.multi: ") |> String.trim()

      assert Jason.decode!(json1)["message"] == "UDP Event 1"
      assert Jason.decode!(json2)["message"] == "UDP Event 2"

      Syslog.close(sink)
    end
  end

  describe "syslog message format" do
    setup do
      {:ok, udp_socket} = :gen_udp.open(0, [:binary, {:active, false}])
      {:ok, port} = :inet.port(udp_socket)

      on_exit(fn ->
        :gen_udp.close(udp_socket)
      end)

      {:ok, udp_socket: udp_socket, port: port}
    end

    test "formats message with correct priority, tag, and JSON body", %{
      event: event,
      udp_socket: udp_socket,
      port: port
    } do
      config = %{
        "network" => "udp",
        "address" => "127.0.0.1:#{port}",
        "tag" => "my.tag"
      }

      {:ok, sink} = Syslog.start_link(config)
      assert :ok = Syslog.send(sink, event)

      {:ok, {_addr, _port, data}} = :gen_udp.recv(udp_socket, 0, 5000)

      # Priority 134 = LOCAL0 (16) * 8 + INFO (6)
      assert String.starts_with?(data, "<134>")

      assert String.contains?(data, "my.tag: ")

      assert String.ends_with?(data, "\n")

      json_part = data |> String.trim_leading("<134>my.tag: ") |> String.trim()
      decoded = Jason.decode!(json_part)
      assert is_map(decoded)
      assert decoded["type"] == "Normal"
      assert decoded["namespace"] == "default"

      Syslog.close(sink)
    end

    test "serializes full event as JSON including nested objects", %{
      event: event,
      udp_socket: udp_socket,
      port: port
    } do
      config = %{
        "network" => "udp",
        "address" => "127.0.0.1:#{port}",
        "tag" => "json.test"
      }

      {:ok, sink} = Syslog.start_link(config)
      assert :ok = Syslog.send(sink, event)

      {:ok, {_addr, _port, data}} = :gen_udp.recv(udp_socket, 0, 5000)
      json_part = data |> String.trim_leading("<134>json.test: ") |> String.trim()
      decoded = Jason.decode!(json_part)

      assert decoded["involved_object"]["kind"] == "Pod"
      assert decoded["involved_object"]["name"] == "test-pod"
      assert decoded["source"]["component"] == "kubelet"

      Syslog.close(sink)
    end
  end

  describe "close/1" do
    test "stops process and closes socket (TCP)" do
      {:ok, listen_socket} =
        :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}])

      {:ok, port} = :inet.port(listen_socket)

      config = %{
        "network" => "tcp",
        "address" => "127.0.0.1:#{port}",
        "tag" => "close.test"
      }

      {:ok, sink} = Syslog.start_link(config)
      {:ok, _server_socket} = :gen_tcp.accept(listen_socket, 5000)
      assert Process.alive?(sink)

      Syslog.close(sink)
      refute Process.alive?(sink)

      :gen_tcp.close(listen_socket)
    end

    test "stops process and closes socket (UDP)" do
      config = %{
        "network" => "udp",
        "address" => "127.0.0.1:9999",
        "tag" => "close.test"
      }

      {:ok, sink} = Syslog.start_link(config)
      assert Process.alive?(sink)

      Syslog.close(sink)
      refute Process.alive?(sink)
    end
  end

  describe "error handling" do
    test "returns error on TCP connection failure" do
      Process.flag(:trap_exit, true)

      config = %{
        "network" => "tcp",
        "address" => "127.0.0.1:1",
        "tag" => "fail.test"
      }

      assert {:error, _reason} = Syslog.start_link(config)
    end

    test "returns error for invalid address format" do
      Process.flag(:trap_exit, true)

      config = %{
        "network" => "tcp",
        "address" => "invalid-address",
        "tag" => "fail.test"
      }

      assert {:error, _reason} = Syslog.start_link(config)
    end
  end
end
