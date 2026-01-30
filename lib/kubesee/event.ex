defmodule Kubesee.Event do
  @moduledoc false

  @derive Jason.Encoder
  defstruct [
    :name,
    :namespace,
    :uid,
    :resource_version,
    :creation_timestamp,
    :labels,
    :annotations,
    :reason,
    :message,
    :type,
    :count,
    :action,
    :reporting_controller,
    :reporting_instance,
    :first_timestamp,
    :last_timestamp,
    :event_time,
    :cluster_name,
    :involved_object,
    :source
  ]

  defmodule ObjectReference do
    @moduledoc false
    @derive Jason.Encoder
    defstruct [
      :kind,
      :namespace,
      :name,
      :uid,
      :api_version,
      :resource_version,
      :field_path,
      :labels,
      :annotations,
      :owner_references,
      :deleted
    ]
  end

  defmodule Source do
    @moduledoc false
    @derive Jason.Encoder
    defstruct [:component, :host]
  end

  def from_k8s_map(k8s_event) do
    metadata = k8s_event["metadata"] || %{}
    involved = k8s_event["involvedObject"] || %{}
    source = k8s_event["source"] || %{}

    %__MODULE__{
      name: metadata["name"],
      namespace: metadata["namespace"],
      uid: metadata["uid"],
      resource_version: metadata["resourceVersion"],
      creation_timestamp: parse_timestamp(metadata["creationTimestamp"]),
      labels: metadata["labels"] || %{},
      annotations: metadata["annotations"] || %{},
      reason: k8s_event["reason"],
      message: k8s_event["message"],
      type: k8s_event["type"],
      count: k8s_event["count"],
      action: k8s_event["action"],
      reporting_controller: k8s_event["reportingController"],
      reporting_instance: k8s_event["reportingInstance"],
      first_timestamp: parse_timestamp(k8s_event["firstTimestamp"]),
      last_timestamp: parse_timestamp(k8s_event["lastTimestamp"]),
      event_time: parse_timestamp(k8s_event["eventTime"]),
      cluster_name: k8s_event["clusterName"],
      involved_object: %ObjectReference{
        kind: involved["kind"],
        namespace: involved["namespace"],
        name: involved["name"],
        uid: involved["uid"],
        api_version: involved["apiVersion"],
        resource_version: involved["resourceVersion"],
        field_path: involved["fieldPath"],
        labels: involved["labels"],
        annotations: involved["annotations"],
        owner_references: involved["ownerReferences"],
        deleted: involved["deleted"] || false
      },
      source: %Source{
        component: source["component"],
        host: source["host"]
      }
    }
  end

  def dedot(%__MODULE__{} = event) do
    %ObjectReference{} = obj = event.involved_object

    updated_object = %{
      obj
      | labels: dedot_map(obj.labels),
        annotations: dedot_map(obj.annotations)
    }

    %{
      event
      | labels: dedot_map(event.labels),
        annotations: dedot_map(event.annotations),
        involved_object: updated_object
    }
  end

  def get_timestamp_ms(%__MODULE__{} = event) do
    case get_event_timestamp(event) do
      nil -> 0
      dt -> DateTime.to_unix(dt, :millisecond)
    end
  end

  def get_timestamp_iso8601(%__MODULE__{} = event) do
    case get_event_timestamp(event) do
      nil -> ""
      dt -> format_timestamp(dt)
    end
  end

  def to_json(%__MODULE__{} = event) do
    Jason.encode!(event)
  end

  def to_template_context(%__MODULE__{} = event) do
    %{
      "Name" => event.name,
      "Namespace" => event.namespace || get_in_safe(event, [:involved_object, :namespace]),
      "UID" => event.uid,
      "ResourceVersion" => event.resource_version,
      "CreationTimestamp" => format_timestamp(event.creation_timestamp),
      "Labels" => event.labels || %{},
      "Annotations" => event.annotations || %{},
      "Message" => event.message,
      "Reason" => event.reason,
      "Type" => event.type,
      "Count" => event.count,
      "Action" => event.action,
      "ReportingController" => event.reporting_controller,
      "ReportingInstance" => event.reporting_instance,
      "FirstTimestamp" => format_timestamp(event.first_timestamp),
      "LastTimestamp" => format_timestamp(event.last_timestamp),
      "EventTime" => format_timestamp(event.event_time),
      "ClusterName" => event.cluster_name,
      "InvolvedObject" => involved_object_context(event.involved_object),
      "Source" => source_context(event.source),
      "GetTimestampMs" => fn -> get_timestamp_ms(event) end,
      "GetTimestampISO8601" => fn -> get_timestamp_iso8601(event) end
    }
  end

  defp involved_object_context(nil) do
    %{
      "Kind" => nil,
      "Namespace" => nil,
      "Name" => nil,
      "UID" => nil,
      "APIVersion" => nil,
      "ResourceVersion" => nil,
      "FieldPath" => nil,
      "Labels" => %{},
      "Annotations" => %{},
      "OwnerReferences" => [],
      "Deleted" => false
    }
  end

  defp involved_object_context(%ObjectReference{} = obj) do
    %{
      "Kind" => obj.kind,
      "Namespace" => obj.namespace,
      "Name" => obj.name,
      "UID" => obj.uid,
      "APIVersion" => obj.api_version,
      "ResourceVersion" => obj.resource_version,
      "FieldPath" => obj.field_path,
      "Labels" => obj.labels || %{},
      "Annotations" => obj.annotations || %{},
      "OwnerReferences" => obj.owner_references || [],
      "Deleted" => obj.deleted || false
    }
  end

  defp source_context(nil), do: %{"Component" => nil, "Host" => nil}

  defp source_context(%Source{} = s) do
    %{"Component" => s.component, "Host" => s.host}
  end

  defp get_event_timestamp(%__MODULE__{first_timestamp: ts}) when not is_nil(ts), do: ts
  defp get_event_timestamp(%__MODULE__{event_time: ts}) when not is_nil(ts), do: ts
  defp get_event_timestamp(_), do: nil

  defp parse_timestamp(nil), do: nil
  defp parse_timestamp(""), do: nil

  defp parse_timestamp(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  defp format_timestamp(nil), do: nil

  defp format_timestamp(%DateTime{} = dt) do
    dt_utc =
      case DateTime.shift_zone(dt, "Etc/UTC") do
        {:ok, shifted} -> shifted
        {:error, _} -> dt
      end

    ms = div(elem(dt_utc.microsecond, 0), 1000)

    formatted =
      :io_lib.format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~3..0BZ", [
        dt_utc.year,
        dt_utc.month,
        dt_utc.day,
        dt_utc.hour,
        dt_utc.minute,
        dt_utc.second,
        ms
      ])

    IO.iodata_to_binary(formatted)
  end

  defp dedot_map(nil), do: nil
  defp dedot_map(map) when map == %{}, do: %{}

  defp dedot_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {String.replace(key, ".", "_"), value}
    end)
  end

  defp get_in_safe(struct, keys) do
    Enum.reduce_while(keys, struct, fn key, acc ->
      case acc do
        nil -> {:halt, nil}
        %{} = map -> {:cont, Map.get(map, key)}
        _ -> {:halt, nil}
      end
    end)
  end
end
