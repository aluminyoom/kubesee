defmodule Kubesee.Engine do
  @moduledoc false

  use Supervisor

  alias Kubesee.Config
  alias Kubesee.Registry
  alias Kubesee.Route
  alias Kubesee.Watcher

  @drain_timeout 30_000
  @task_supervisor Kubesee.Engine.TaskSupervisor

  def start_link(%Config{} = config) do
    Supervisor.start_link(__MODULE__, config)
  end

  @impl Supervisor
  def init(%Config{} = config) do
    conn = Map.fetch!(config, :conn)

    on_event = fn event ->
      event = %{event | cluster_name: config.cluster_name}
      Route.process_event(config.route, event, &Registry.send/2)
    end

    children = [
      Supervisor.child_spec({Task.Supervisor, name: @task_supervisor}, id: @task_supervisor),
      Supervisor.child_spec({Registry, receivers: config.receivers}, id: Registry),
      Supervisor.child_spec(
        {Watcher,
         conn: conn,
         namespace: config.namespace,
         max_event_age_seconds: config.max_event_age_seconds,
         omit_lookup: config.omit_lookup,
         on_event: on_event},
        id: Watcher,
        restart: :transient
      )
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def stop(engine) do
    engine
    |> resolve_engine_pid()
    |> do_stop()
  end

  defp do_stop(nil), do: :ok

  defp do_stop(engine_pid) do
    if Process.alive?(engine_pid) do
      engine_pid
      |> child_pid(Watcher)
      |> stop_watcher()

      engine_pid
      |> child_pid(Registry)
      |> drain_and_close()
    end

    :ok
  end

  defp stop_watcher(nil), do: :ok

  defp stop_watcher(watcher) do
    if Process.alive?(watcher) do
      _ = Watcher.stop(watcher)
    end

    :ok
  end

  defp drain_and_close(nil), do: :ok

  defp drain_and_close(registry) do
    if Process.alive?(registry) do
      _ = Registry.drain_all(registry, @drain_timeout)
      _ = Registry.close_all(registry)
    end

    :ok
  end

  defp child_pid(engine, child_id) do
    engine
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^child_id, pid, _type, _modules} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  defp resolve_engine_pid(pid) when is_pid(pid), do: pid
  defp resolve_engine_pid(name), do: Process.whereis(name)
end
