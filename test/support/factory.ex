defmodule Kubesee.Factory do
  @moduledoc false

  def k8s_event(overrides \\ %{}) do
    now = DateTime.to_iso8601(DateTime.utc_now())

    base = %{
      "apiVersion" => "v1",
      "kind" => "Event",
      "metadata" => %{
        "name" => "test-event-#{:rand.uniform(10_000)}",
        "namespace" => "default",
        "uid" => uuid(),
        "resourceVersion" => "#{:rand.uniform(100_000)}"
      },
      "involvedObject" => %{
        "kind" => "Pod",
        "name" => "test-pod",
        "namespace" => "default",
        "uid" => uuid(),
        "apiVersion" => "v1"
      },
      "reason" => "Created",
      "message" => "Pod created",
      "type" => "Normal",
      "firstTimestamp" => now,
      "lastTimestamp" => now,
      "source" => %{
        "component" => "kubelet",
        "host" => "node-1"
      }
    }

    deep_merge(base, overrides)
  end

  def watch_event(type \\ "ADDED", overrides \\ %{}) do
    %{
      "type" => type,
      "object" => k8s_event(overrides)
    }
  end

  defp uuid do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> String.replace(~r/(.{8})(.{4})(.{4})(.{4})(.{12})/, "\\1-\\2-\\3-\\4-\\5")
  end

  defp deep_merge(base, overrides) when is_map(base) and is_map(overrides) do
    Map.merge(base, overrides, fn
      _k, v1, v2 when is_map(v1) and is_map(v2) -> deep_merge(v1, v2)
      _k, _v1, v2 -> v2
    end)
  end
end
