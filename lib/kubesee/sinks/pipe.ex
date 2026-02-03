defmodule Kubesee.Sinks.Pipe do
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
    path = config["path"]

    case File.open(path, [:write]) do
      {:ok, file} ->
        {:ok, %{config: config, path: path, file: file}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:send, event}, _from, state) do
    event = maybe_dedot(event, state.config)

    case serialize_event(event, state.config) do
      {:ok, json} ->
        data = json <> "\n"

        case IO.binwrite(state.file, data) do
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
  def terminate(_reason, %{file: file}) when not is_nil(file) do
    File.close(file)
    :ok
  end

  def terminate(_reason, _state), do: :ok
end
