defmodule Kubesee.Sinks.InMemory do
  @moduledoc false

  use GenServer

  @behaviour Kubesee.Sink

  alias Kubesee.Event

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

  @spec get_events(pid()) :: [Event.t()]
  def get_events(sink) do
    GenServer.call(sink, :get_events)
  end

  @spec clear(pid()) :: :ok
  def clear(sink) do
    GenServer.call(sink, :clear)
  end

  @impl GenServer
  def init(config) do
    ref = config["ref"] || "default"
    table = :ets.new(:kubesee_in_memory_sink, [:ordered_set, :private])
    {:ok, %{ref: ref, table: table, counter: 0}}
  end

  @impl GenServer
  def handle_call({:send, event}, _from, state) do
    :ets.insert(state.table, {state.counter, event})
    {:reply, :ok, %{state | counter: state.counter + 1}}
  end

  @impl GenServer
  def handle_call(:get_events, _from, state) do
    events =
      state.table
      |> :ets.tab2list()
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    {:reply, events, state}
  end

  @impl GenServer
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, %{state | counter: 0}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    :ets.delete(state.table)
    :ok
  end
end
