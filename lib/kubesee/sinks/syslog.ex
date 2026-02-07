defmodule Kubesee.Sinks.Syslog do
  @moduledoc false

  use GenServer

  @behaviour Kubesee.Sink

  require Logger

  # LOCAL0 (16) * 8 + INFO (6)
  @syslog_priority 134

  @impl Kubesee.Sink
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl Kubesee.Sink
  def send(sink, event) do
    GenServer.call(sink, {:send, event})
  end

  @impl Kubesee.Sink
  def close(sink) do
    GenServer.stop(sink)
  end

  @impl GenServer
  def init(config) do
    network = config["network"]
    tag = config["tag"] || "kubesee"

    case parse_address(config["address"]) do
      {:ok, host, port} ->
        case connect(network, host, port) do
          {:ok, conn} ->
            {:ok, %{conn: conn, tag: tag}}

          {:error, reason} ->
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:send, event}, _from, %{conn: conn, tag: tag} = state) do
    case Jason.encode(event) do
      {:ok, json} ->
        message = "<#{@syslog_priority}>#{tag}: #{json}\n"

        case send_message(conn, message) do
          :ok ->
            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def terminate(_reason, %{conn: {:tcp, socket}}) do
    :gen_tcp.close(socket)
    :ok
  end

  def terminate(_reason, %{conn: {:udp, socket, _dest}}) do
    :gen_udp.close(socket)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp parse_address(address) when is_binary(address) do
    case String.split(address, ":") do
      [host, port_str] ->
        case Integer.parse(port_str) do
          {port, ""} -> {:ok, host, port}
          _ -> {:error, :invalid_port}
        end

      _ ->
        {:error, :invalid_address}
    end
  end

  defp parse_address(_), do: {:error, :invalid_address}

  defp connect("tcp", host, port) do
    case :gen_tcp.connect(to_charlist(host), port, [:binary, {:active, false}]) do
      {:ok, socket} -> {:ok, {:tcp, socket}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp connect("udp", host, port) do
    case :gen_udp.open(0, [:binary]) do
      {:ok, socket} -> {:ok, {:udp, socket, {to_charlist(host), port}}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp connect(_, _host, _port), do: {:error, :unsupported_network}

  defp send_message({:tcp, socket}, message) do
    :gen_tcp.send(socket, message)
  end

  defp send_message({:udp, socket, {host, port}}, message) do
    :gen_udp.send(socket, host, port, message)
  end
end
