defmodule Kubesee.WatcherTest do
  use ExUnit.Case

  import Mox

  alias Kubesee.Event
  alias Kubesee.Factory
  alias Kubesee.Watcher

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    {:ok, conn: %{test: :conn}}
  end

  defp start_watcher!(opts) do
    {:ok, pid} = Watcher.start_link(opts)

    on_exit(fn ->
      if Process.alive?(pid) do
        Watcher.stop(pid)
      end
    end)

    pid
  end

  test "invokes on_event for ADDED events only", %{conn: conn} do
    test_pid = self()

    added = Factory.watch_event("ADDED", %{"metadata" => %{"name" => "added"}})
    modified = Factory.watch_event("MODIFIED", %{"metadata" => %{"name" => "modified"}})
    deleted = Factory.watch_event("DELETED", %{"metadata" => %{"name" => "deleted"}})
    stream = [modified, added, deleted]

    expect(Kubesee.K8sClientMock, :watch_events, fn ^conn, "default" ->
      {:ok, stream}
    end)

    start_watcher!(
      conn: conn,
      namespace: "default",
      max_event_age_seconds: 60,
      omit_lookup: true,
      on_event: fn event -> send(test_pid, {:event, event}) end
    )

    assert_receive {:event, %Event{name: "added"}}
    refute_receive {:event, %Event{name: "modified"}}, 100
    refute_receive {:event, %Event{name: "deleted"}}, 100
  end

  test "skips events older than max_event_age_seconds", %{conn: conn} do
    test_pid = self()

    now = DateTime.utc_now()
    old_iso = now |> DateTime.add(-120, :second) |> DateTime.to_iso8601()
    new_iso = DateTime.to_iso8601(now)

    old_event = Factory.watch_event("ADDED", %{"metadata" => %{"name" => "old"}, "lastTimestamp" => old_iso})
    new_event = Factory.watch_event("ADDED", %{"metadata" => %{"name" => "new"}, "lastTimestamp" => new_iso})

    expect(Kubesee.K8sClientMock, :watch_events, fn ^conn, "default" ->
      {:ok, [old_event, new_event]}
    end)

    start_watcher!(
      conn: conn,
      namespace: "default",
      max_event_age_seconds: 60,
      omit_lookup: true,
      on_event: fn event -> send(test_pid, {:event, event}) end
    )

    assert_receive {:event, %Event{name: "new"}}
    refute_receive {:event, %Event{name: "old"}}, 100
  end

  test "invokes on_event callback with Event struct", %{conn: conn} do
    test_pid = self()

    event = Factory.watch_event("ADDED", %{"metadata" => %{"name" => "callback"}})

    expect(Kubesee.K8sClientMock, :watch_events, fn ^conn, "default" ->
      {:ok, [event]}
    end)

    start_watcher!(
      conn: conn,
      namespace: "default",
      max_event_age_seconds: 60,
      omit_lookup: true,
      on_event: fn received -> send(test_pid, {:event, received}) end
    )

    assert_receive {:event, %Event{name: "callback", involved_object: %Event.ObjectReference{}}}
  end

  test "omit_lookup true skips resource lookup", %{conn: conn} do
    test_pid = self()

    event = Factory.watch_event("ADDED", %{"metadata" => %{"name" => "omit"}})

    expect(Kubesee.K8sClientMock, :watch_events, fn ^conn, "default" ->
      {:ok, [event]}
    end)

    stub(Kubesee.K8sClientMock, :get_resource, fn _conn, _api_version, _kind, _namespace, _name ->
      send(test_pid, :lookup_called)
      {:ok, %{"metadata" => %{}}}
    end)

    start_watcher!(
      conn: conn,
      namespace: "default",
      max_event_age_seconds: 60,
      omit_lookup: true,
      on_event: fn received -> send(test_pid, {:event, received}) end
    )

    assert_receive {:event, %Event{name: "omit"}}
    refute_receive :lookup_called, 100
  end

  test "enriches involved object metadata when omit_lookup is false", %{conn: conn} do
    test_pid = self()

    event =
      Factory.watch_event("ADDED", %{
        "metadata" => %{"name" => "enrich"},
        "involvedObject" => %{"name" => "test-pod", "namespace" => "default", "apiVersion" => "v1", "kind" => "Pod"}
      })

    resource = %{
      "apiVersion" => "v1",
      "kind" => "Pod",
      "metadata" => %{
        "name" => "test-pod",
        "namespace" => "default",
        "labels" => %{"app" => "demo"},
        "annotations" => %{"note" => "updated"},
        "ownerReferences" => [%{"kind" => "ReplicaSet", "name" => "rs-1"}],
        "resourceVersion" => "99"
      }
    }

    expect(Kubesee.K8sClientMock, :watch_events, fn ^conn, "default" ->
      {:ok, [event]}
    end)

    expect(Kubesee.K8sClientMock, :get_resource, fn ^conn, "v1", "Pod", "default", "test-pod" ->
      {:ok, resource}
    end)

    start_watcher!(
      conn: conn,
      namespace: "default",
      max_event_age_seconds: 60,
      omit_lookup: false,
      on_event: fn received -> send(test_pid, {:event, received}) end
    )

    assert_receive {:event, %Event{involved_object: involved}}
    assert involved.labels == %{"app" => "demo"}
    assert involved.annotations == %{"note" => "updated"}
    assert involved.owner_references == [%{"kind" => "ReplicaSet", "name" => "rs-1"}]
    assert involved.resource_version == "99"
    assert involved.deleted == false
  end
end
