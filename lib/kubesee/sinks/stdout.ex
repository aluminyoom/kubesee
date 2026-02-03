defmodule Kubesee.Sinks.Stdout do
  @moduledoc false

  use GenServer

  @behaviour Kubesee.Sink

  import Kubesee.Sinks.Common, only: [maybe_dedot: 2, serialize_event: 2]

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
    device = config["_device"] || :stdio
    {:ok, %{config: config, device: device}}
  end

  @impl GenServer
  def handle_call({:send, event}, _from, %{config: config, device: device} = state) do
    event = maybe_dedot(event, config)

    case serialize_event(event, config) do
      {:ok, json} ->
        IO.puts(device, json)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end
end
