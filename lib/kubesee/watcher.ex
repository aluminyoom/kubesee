defmodule Kubesee.Watcher do
  @moduledoc false

  use GenServer

  alias Kubesee.Event

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def stop(watcher) do
    GenServer.call(watcher, :stop)
  end

  @impl GenServer
  def init(opts) do
    conn = Keyword.fetch!(opts, :conn)
    namespace = Keyword.get(opts, :namespace)
    max_event_age_seconds = Keyword.fetch!(opts, :max_event_age_seconds)
    omit_lookup = Keyword.get(opts, :omit_lookup, false)
    on_event = Keyword.fetch!(opts, :on_event)

    state = %{
      conn: conn,
      namespace: namespace,
      max_event_age_seconds: max_event_age_seconds,
      omit_lookup: omit_lookup,
      on_event: on_event,
      stream_task: nil
    }

    case k8s_client().watch_events(conn, namespace) do
      {:ok, stream} ->
        task = start_stream_task(stream)
        {:ok, %{state | stream_task: task}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:stop, _from, state) do
    state = cancel_stream_task(state)
    {:stop, :normal, :ok, state}
  end

  @impl GenServer
  def handle_info(
        {ref, %{"type" => "ADDED", "object" => object}},
        %{stream_task: %Task{ref: ref}} = state
      ) do
    event = Event.from_k8s_map(object)

    if discard_event?(event, state.max_event_age_seconds) do
      {:noreply, state}
    else
      event = maybe_enrich_event(event, state)
      state.on_event.(event)
      {:noreply, state}
    end
  end

  def handle_info({ref, %{"type" => _type}}, %{stream_task: %Task{ref: ref}} = state) do
    {:noreply, state}
  end

  def handle_info({ref, _result}, %{stream_task: %Task{ref: ref}} = state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{stream_task: %Task{ref: ref}} = state) do
    {:noreply, %{state | stream_task: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    _ = cancel_stream_task(state)
    :ok
  end

  defp start_stream_task(stream) do
    parent = self()

    task =
      Task.async(fn ->
        receive do
          {:init, ref} ->
            Enum.each(stream, fn item ->
              send(parent, {ref, item})
            end)
        end
      end)

    send(task.pid, {:init, task.ref})
    task
  end

  defp discard_event?(%Event{} = event, max_event_age_seconds)
       when is_integer(max_event_age_seconds) do
    case event.last_timestamp || event.event_time do
      %DateTime{} = timestamp ->
        age = DateTime.diff(DateTime.utc_now(), timestamp, :second)
        age > max_event_age_seconds

      _ ->
        false
    end
  end

  defp discard_event?(_event, _max_event_age_seconds), do: false

  defp maybe_enrich_event(%Event{} = event, %{omit_lookup: true}), do: event

  defp maybe_enrich_event(%Event{} = event, %{conn: conn}) do
    %Event.ObjectReference{} = involved = event.involved_object

    with api_version when is_binary(api_version) <- involved.api_version,
         kind when is_binary(kind) <- involved.kind,
         namespace when is_binary(namespace) <- involved.namespace,
         name when is_binary(name) <- involved.name do
      case k8s_client().get_resource(conn, api_version, kind, namespace, name) do
        {:ok, resource} ->
          enrich_event(event, resource)

        {:error, :not_found} ->
          %{event | involved_object: %Event.ObjectReference{involved | deleted: true}}

        {:error, _} ->
          event
      end
    else
      _ -> event
    end
  end

  defp enrich_event(%Event{} = event, %{} = resource) do
    metadata = resource["metadata"] || %{}
    %Event.ObjectReference{} = involved = event.involved_object

    updated_involved = %Event.ObjectReference{
      involved
      | labels: metadata["labels"],
        annotations: metadata["annotations"],
        owner_references: metadata["ownerReferences"],
        resource_version: metadata["resourceVersion"],
        deleted: Map.get(metadata, "deleted", false)
    }

    %{event | involved_object: updated_involved}
  end

  defp cancel_stream_task(%{stream_task: %Task{} = task} = state) do
    _ = Task.shutdown(task, :brutal_kill)
    %{state | stream_task: nil}
  end

  defp cancel_stream_task(state), do: state

  defp k8s_client do
    Application.get_env(:kubesee, :k8s_client, Kubesee.K8sClient)
  end
end
