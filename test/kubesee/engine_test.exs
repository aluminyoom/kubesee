defmodule Kubesee.EngineTest do
  use ExUnit.Case, async: false

  import Mox

  alias Kubesee.Config
  alias Kubesee.Config.Receiver
  alias Kubesee.Engine
  alias Kubesee.Event
  alias Kubesee.Factory
  alias Kubesee.Route
  alias Kubesee.Rule

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    {:ok, conn: %{test: :conn}}
  end

  defp config(conn, cluster_name \\ "test-cluster") do
    Map.put(
      %Config{
        route: %Route{match: [%Rule{receiver: "stdout"}]},
        receivers: [%Receiver{name: "stdout", sink_type: :stdout, sink_config: %{}}],
        cluster_name: cluster_name,
        max_event_age_seconds: 60,
        namespace: "default",
        omit_lookup: true
      },
      :conn,
      conn
    )
  end

  defp start_engine!(%Config{} = config) do
    {:ok, pid} = Engine.start_link(config)
    Process.unlink(pid)

    on_exit(fn ->
      stop_engine(pid)
    end)

    pid
  end

  defp stop_engine(pid) do
    if Process.alive?(pid) do
      _ = Engine.stop(pid)
    end

    if Process.alive?(pid) do
      GenServer.stop(pid)
    end
  end

  defp blocking_stream do
    Stream.repeatedly(fn -> Process.sleep(:infinity) end)
  end

  defp child_pids(engine) do
    engine
    |> Supervisor.which_children()
    |> Enum.reduce(%{}, fn
      {Kubesee.Engine.TaskSupervisor, pid, _type, _modules}, acc ->
        Map.put(acc, :task_supervisor, pid)

      {Kubesee.Registry, pid, _type, _modules}, acc ->
        Map.put(acc, :registry, pid)

      {Kubesee.Watcher, pid, _type, _modules}, acc ->
        Map.put(acc, :watcher, pid)

      _, acc ->
        acc
    end)
  end

  test "start_link starts task supervisor, registry, and watcher", %{conn: conn} do
    expect(Kubesee.K8sClientMock, :watch_events, fn ^conn, "default" ->
      {:ok, []}
    end)

    engine = start_engine!(config(conn))

    %{task_supervisor: task_pid, registry: registry_pid, watcher: watcher_pid} = child_pids(engine)

    assert Process.alive?(task_pid)
    assert Process.whereis(Kubesee.Engine.TaskSupervisor) == task_pid
    assert Process.alive?(registry_pid)
    assert Process.alive?(watcher_pid)
  end

  test "routes watcher events to registry with cluster name injection", %{conn: conn} do
    expect(Kubesee.K8sClientMock, :watch_events, fn ^conn, "default" ->
      {:ok, blocking_stream()}
    end)

    engine = start_engine!(config(conn, "cluster-a"))

    %{registry: registry, watcher: watcher} = child_pids(engine)

    :erlang.trace(registry, true, [:receive])

    %{stream_task: %{ref: ref}} = :sys.get_state(watcher)
    object = Factory.k8s_event(%{"metadata" => %{"name" => "engine-event"}})
    send(watcher, {ref, %{"type" => "ADDED", "object" => object}})

    assert_receive {:trace, ^registry, :receive,
                    {:"$gen_cast",
                     {:send, "stdout",
                      %Event{name: "engine-event", cluster_name: "cluster-a"}}}},
                   1_000

    :erlang.trace(registry, false, [:receive])
  end

  test "stop/1 stops watcher, drains registry, and closes sinks", %{conn: conn} do
    expect(Kubesee.K8sClientMock, :watch_events, fn ^conn, "default" ->
      {:ok, []}
    end)

    engine = start_engine!(config(conn))

    %{registry: registry, watcher: watcher} = child_pids(engine)

    :erlang.trace(registry, true, [:receive])

    assert :ok = Engine.stop(engine)

    assert_receive {:trace, ^registry, :receive, {:"$gen_call", _from, :receivers}}, 1_000

    assert_receive {:trace, ^registry, :receive,
                    {:"$gen_call", _from, {:drain, "stdout", 30_000}}}, 1_000

    assert_receive {:trace, ^registry, :receive, {:"$gen_call", _from, :close_all}}, 1_000

    refute Process.alive?(watcher)
    assert %{} = :sys.get_state(registry).sinks

    :erlang.trace(registry, false, [:receive])
  end
end
