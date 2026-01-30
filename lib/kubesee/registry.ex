defmodule Kubesee.Registry do
  @moduledoc false

  use GenServer

  require Logger

  alias Kubesee.Config.Receiver

  @default_max_queue_size 1_000
  @default_drain_timeout 30_000

  def start_link(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.has_key?(opts, :receivers) do
      receivers = Keyword.fetch!(opts, :receivers)
      start_link(receivers, Keyword.delete(opts, :receivers))
    else
      start_link(opts, [])
    end
  end

  def start_link(receivers, opts) when is_list(receivers) and is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    genserver_opts = if is_nil(name), do: [], else: [name: name]
    init_opts = Keyword.drop(opts, [:name])

    GenServer.start_link(__MODULE__, {receivers, init_opts}, genserver_opts)
  end

  def register(registry, %Receiver{} = receiver) do
    GenServer.call(registry, {:register, receiver})
  end

  def send(receiver, event) when is_binary(receiver) do
    send(__MODULE__, receiver, event)
  end

  def send(registry, {receiver, event}) when is_binary(receiver) do
    send(registry, receiver, event)
  end

  def send(registry, receiver, event) do
    GenServer.cast(registry, {:send, receiver, event})
  end

  def drain(registry, receiver, timeout \\ @default_drain_timeout) do
    GenServer.call(registry, {:drain, receiver, timeout}, timeout + 1_000)
  end

  def drain_all(registry, timeout \\ @default_drain_timeout) do
    receivers = GenServer.call(registry, :receivers)

    Enum.reduce_while(receivers, :ok, fn receiver, :ok ->
      case drain(registry, receiver, timeout) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def close(registry, receiver) do
    GenServer.call(registry, {:close, receiver})
  end

  def close_all(registry) do
    GenServer.call(registry, :close_all)
  end

  @impl GenServer
  def init({receivers, opts}) do
    {:ok, task_sup} = Task.Supervisor.start_link()
    max_queue_size = Keyword.get(opts, :max_queue_size, @default_max_queue_size)

    state = %{
      sinks: %{},
      queues: %{},
      task_sup: task_sup,
      max_queue_size: max_queue_size,
      drain_waiters: %{},
      sink_modules: %{}
    }

    case register_receivers(receivers, state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:register, receiver}, _from, state) do
    case register_receiver(receiver, state) do
      {:ok, state, pid} -> {:reply, {:ok, pid}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:receivers, _from, state) do
    {:reply, Map.keys(state.sinks), state}
  end

  def handle_call({:drain, receiver, timeout}, from, state) do
    case Map.fetch(state.queues, receiver) do
      {:ok, queue} ->
        if :queue.is_empty(queue) do
          {:reply, :ok, state}
        else
          timer_ref = Process.send_after(self(), {:drain_timeout, receiver, from}, timeout)
          waiters = Map.get(state.drain_waiters, receiver, [])
          new_waiters = [{from, timer_ref} | waiters]

          new_state = put_in(state.drain_waiters[receiver], new_waiters)

          {:noreply, new_state}
        end

      :error ->
        {:reply, {:error, :unknown_receiver}, state}
    end
  end

  def handle_call({:close, receiver}, _from, state) do
    case close_receiver(state, receiver) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:close_all, _from, state) do
    state =
      Enum.reduce(state.sinks, state, fn {receiver, _pid}, acc ->
        case close_receiver(acc, receiver) do
          {:ok, updated} -> updated
          {:error, _} -> acc
        end
      end)

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast({:send, receiver, event}, state) do
    case Map.fetch(state.sinks, receiver) do
      {:ok, sink_pid} ->
        queue = Map.get(state.queues, receiver, :queue.new())

        if :queue.len(queue) >= state.max_queue_size do
          Logger.warning("sink queue full for receiver #{receiver}, dropping event")
          {:noreply, state}
        else
          new_queue = :queue.in(event, queue)
          new_state = put_in(state.queues[receiver], new_queue)
          sink_module = Map.get(state.sink_modules, receiver)
          dispatch_event(receiver, sink_pid, sink_module, event, new_state)
        end

      :error ->
        Logger.warning("unknown receiver #{receiver}, dropping event")
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:dispatched, receiver}, state) do
    {state, empty?} = dequeue_event(state, receiver)
    state = if empty?, do: flush_drainers(state, receiver, :ok), else: state
    {:noreply, state}
  end

  def handle_info({:drain_timeout, receiver, from}, state) do
    waiters = Map.get(state.drain_waiters, receiver, [])

    {timed_out, remaining} =
      Enum.split_with(waiters, fn {waiter_from, _timer_ref} -> waiter_from == from end)

    Enum.each(timed_out, fn {waiter_from, _timer_ref} ->
      GenServer.reply(waiter_from, {:error, :timeout})
    end)

    new_state =
      if remaining == [] do
        %{state | drain_waiters: Map.delete(state.drain_waiters, receiver)}
      else
        put_in(state.drain_waiters[receiver], remaining)
      end

    {:noreply, new_state}
  end

  defp register_receivers(receivers, state) do
    Enum.reduce_while(receivers, {:ok, state}, fn receiver, {:ok, acc} ->
      case register_receiver(receiver, acc) do
        {:ok, updated, _pid} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp register_receiver(%Receiver{name: name} = receiver, state) do
    if Map.has_key?(state.sinks, name) do
      {:error, :already_registered}
    else
      with {:ok, sink_module} <- sink_module(receiver.sink_type),
           {:ok, sink_pid} <- sink_module.start_link(receiver.sink_config || %{}) do
        new_state = %{
          state
          | sinks: Map.put(state.sinks, name, sink_pid),
            queues: Map.put(state.queues, name, :queue.new()),
            sink_modules: Map.put(state.sink_modules, name, sink_module)
        }

        {:ok, new_state, sink_pid}
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp sink_module(:stdout), do: {:ok, Kubesee.Sink.Stdout}
  defp sink_module(other), do: {:error, {:unsupported_sink, other}}

  defp dispatch_event(receiver, sink_pid, sink_module, event, state) do
    registry = self()

    task = fn ->
      try do
        if sink_module do
          _ = sink_module.send(sink_pid, event)
        end
      rescue
        _ -> :ok
      after
        Kernel.send(registry, {:dispatched, receiver})
      end
    end

    case Task.Supervisor.start_child(state.task_sup, task) do
      {:ok, _pid} ->
        {:noreply, state}

      {:error, reason} ->
        Logger.warning(
          "failed to dispatch event for receiver #{receiver}: #{inspect(reason)}"
        )

        Kernel.send(registry, {:dispatched, receiver})
        {:noreply, state}
    end
  end

  defp dequeue_event(state, receiver) do
    case Map.fetch(state.queues, receiver) do
      {:ok, queue} ->
        case :queue.out(queue) do
          {{:value, _event}, new_queue} ->
            new_state = put_in(state.queues[receiver], new_queue)
            {new_state, :queue.is_empty(new_queue)}

          {:empty, _} ->
            {state, true}
        end

      :error ->
        {state, true}
    end
  end

  defp close_receiver(state, receiver) do
    case Map.fetch(state.sinks, receiver) do
      {:ok, sink_pid} ->
        sink_module = Map.get(state.sink_modules, receiver)

        if sink_module do
          _ = sink_module.close(sink_pid)
        end

        new_state = %{
          state
          | sinks: Map.delete(state.sinks, receiver),
            queues: Map.delete(state.queues, receiver),
            sink_modules: Map.delete(state.sink_modules, receiver)
        }

        new_state = flush_drainers(new_state, receiver, :ok)

        {:ok, new_state}

      :error ->
        {:error, :unknown_receiver}
    end
  end

  defp flush_drainers(state, receiver, reply) do
    {waiters, drain_waiters} = Map.pop(state.drain_waiters, receiver, [])

    Enum.each(waiters, fn {from, timer_ref} ->
      Process.cancel_timer(timer_ref)
      GenServer.reply(from, reply)
    end)

    %{state | drain_waiters: drain_waiters}
  end
end
