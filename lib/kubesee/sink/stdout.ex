defmodule Kubesee.Sink.Stdout do
  @moduledoc false

  use GenServer

  @behaviour Kubesee.Sink

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
    {:ok, %{config: config}}
  end

  @impl GenServer
  def handle_call({:send, event}, _from, state) do
    json = Jason.encode!(event)
    IO.puts(json)
    {:reply, :ok, state}
  end
end
