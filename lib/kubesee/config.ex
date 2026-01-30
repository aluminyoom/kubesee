defmodule Kubesee.Config do
  @moduledoc false

  require Logger

  @known_sinks ~w(
    stdout file webhook pipe syslog elasticsearch opensearch kafka loki
    kinesis firehose sqs sns eventbridge opscenter pubsub bigquery
    slack teams opsgenie inMemory
  )

  defstruct [
    :log_level,
    :log_format,
    :throttle_period,
    :max_event_age_seconds,
    :cluster_name,
    :namespace,
    :leader_election,
    :route,
    :receivers,
    :kube_qps,
    :kube_burst,
    :metrics_name_prefix,
    :omit_lookup,
    :cache_size
  ]

  def parse(yaml_string) do
    expanded = expand_env(yaml_string)

    case YamlElixir.read_from_string(expanded, atoms: false) do
      {:ok, parsed} ->
        build_config(parsed)

      {:error, %YamlElixir.ParsingError{} = err} ->
        {:error, "YAML parse error: #{Exception.message(err)}"}

      {:error, reason} ->
        {:error, "YAML parse error: #{inspect(reason)}"}
    end
  end

  def expand_env(yaml_string) do
    yaml_string
    |> String.replace("$$", "\x00DOLLAR\x00")
    |> expand_braced_vars()
    |> expand_bare_vars()
    |> String.replace("\x00DOLLAR\x00", "$")
  end

  defp expand_braced_vars(str) do
    Regex.replace(~r/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/, str, fn _, var ->
      System.get_env(var) || ""
    end)
  end

  defp expand_bare_vars(str) do
    Regex.replace(~r/\$([A-Za-z_][A-Za-z0-9_]*)/, str, fn _, var ->
      System.get_env(var) || ""
    end)
  end

  defp build_config(parsed) do
    with {:ok, receivers} <- parse_receivers(parsed["receivers"]),
         {:ok, route} <- parse_route(parsed["route"]),
         {:ok, leader_election} <- parse_leader_election(parsed["leaderElection"]),
         config <- build_struct(parsed, receivers, route, leader_election) do
      apply_defaults(config)
    end
  end

  defp build_struct(parsed, receivers, route, leader_election) do
    %__MODULE__{
      log_level: parsed["logLevel"] || "info",
      log_format: parsed["logFormat"] || "json",
      throttle_period: parsed["throttlePeriod"] || 0,
      max_event_age_seconds: parsed["maxEventAgeSeconds"] || 0,
      cluster_name: parsed["clusterName"] || "",
      namespace: parsed["namespace"],
      leader_election: leader_election,
      route: route,
      receivers: receivers,
      kube_qps: (parsed["kubeQPS"] || 0) / 1,
      kube_burst: parsed["kubeBurst"] || 0,
      metrics_name_prefix: parsed["metricsNamePrefix"],
      omit_lookup: parsed["omitLookup"] || false,
      cache_size: parsed["cacheSize"] || 0
    }
  end

  defp apply_defaults(config) do
    config
    |> default_cache_size()
    |> default_kube_qps()
    |> default_kube_burst()
    |> default_metrics_prefix()
    |> apply_env_overrides()
    |> default_max_event_age()
  end

  defp default_cache_size(%{cache_size: 0} = c), do: %{c | cache_size: 1024}
  defp default_cache_size(c), do: c

  defp default_kube_qps(%{kube_qps: qps} = c) when qps == 0 or qps == 0.0, do: %{c | kube_qps: 5.0}
  defp default_kube_qps(c), do: c

  defp default_kube_burst(%{kube_burst: 0} = c), do: %{c | kube_burst: 10}
  defp default_kube_burst(c), do: c

  defp default_metrics_prefix(%{metrics_name_prefix: nil} = c),
    do: %{c | metrics_name_prefix: "kubesee_"}

  defp default_metrics_prefix(%{metrics_name_prefix: ""} = c),
    do: %{c | metrics_name_prefix: "kubesee_"}

  defp default_metrics_prefix(c), do: c

  defp apply_env_overrides(config) do
    config
    |> maybe_override(:metrics_name_prefix, "KUBESEE_METRICS_PREFIX")
    |> maybe_override(:log_level, "KUBESEE_LOG_LEVEL")
  end

  defp maybe_override(config, key, env_var) do
    case System.get_env(env_var) do
      nil -> config
      value -> Map.put(config, key, value)
    end
  end

  defp default_max_event_age(%{throttle_period: 0, max_event_age_seconds: 0} = c) do
    {:ok, %{c | max_event_age_seconds: 5}}
  end

  defp default_max_event_age(%{throttle_period: t, max_event_age_seconds: m})
       when t != 0 and m != 0 do
    {:error, "cannot set both throttlePeriod (deprecated) and maxEventAgeSeconds"}
  end

  defp default_max_event_age(%{throttle_period: t, max_event_age_seconds: 0} = c) when t != 0 do
    Logger.warning(
      "config.throttlePeriod is deprecated, consider using config.maxEventAgeSeconds instead"
    )

    {:ok, %{c | max_event_age_seconds: t}}
  end

  defp default_max_event_age(c), do: {:ok, c}

  defp parse_receivers(nil), do: {:error, "receivers list is required"}
  defp parse_receivers([]), do: {:error, "receivers list cannot be empty"}

  defp parse_receivers(receivers) when is_list(receivers) do
    receivers
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {receiver_map, idx}, {:ok, acc} ->
      case parse_receiver(receiver_map, idx) do
        {:ok, receiver} -> {:cont, {:ok, [receiver | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, receivers} -> {:ok, Enum.reverse(receivers)}
      error -> error
    end
  end

  defp parse_receiver(receiver_map, idx) do
    name = receiver_map["name"]

    if is_nil(name) or name == "" do
      {:error, "receiver at index #{idx} missing required 'name' field"}
    else
      case find_sink_config(receiver_map, name) do
        {:ok, sink_type, sink_config} ->
          {:ok,
           %Kubesee.Config.Receiver{
             name: name,
             sink_type: sink_type,
             sink_config: sink_config
           }}

        {:error, _} = err ->
          err
      end
    end
  end

  defp find_sink_config(receiver_map, name) do
    sink_keys =
      receiver_map
      |> Map.keys()
      |> Enum.filter(&(&1 != "name"))

    known_sink_keys = Enum.filter(sink_keys, &(&1 in @known_sinks))
    unknown_sink_keys = Enum.filter(sink_keys, &(&1 not in @known_sinks))

    cond do
      unknown_sink_keys != [] and known_sink_keys == [] ->
        unknown = hd(unknown_sink_keys)

        {:error,
         "receiver '#{name}' has unknown sink type '#{unknown}'. Supported: #{Enum.join(@known_sinks, ", ")}"}

      known_sink_keys == [] ->
        {:error, "receiver '#{name}' has no sink configuration"}

      match?([_, _ | _], known_sink_keys) ->
        {:error,
         "receiver '#{name}' has multiple sink configurations (#{Enum.join(known_sink_keys, ", ")}), only one allowed"}

      true ->
        sink_key = hd(known_sink_keys)
        sink_config = receiver_map[sink_key] || %{}
        {:ok, String.to_atom(sink_key), sink_config}
    end
  end

  defp parse_route(nil), do: {:ok, %Kubesee.Route{drop: [], match: [], routes: []}}

  defp parse_route(route_map) when is_map(route_map) do
    {:ok,
     %Kubesee.Route{
       drop: parse_rules(route_map["drop"]),
       match: parse_rules(route_map["match"]),
       routes: parse_sub_routes(route_map["routes"])
     }}
  end

  defp parse_rules(nil), do: []

  defp parse_rules(rules) when is_list(rules) do
    Enum.map(rules, &parse_rule/1)
  end

  defp parse_rule(rule_map) when is_map(rule_map) do
    %Kubesee.Rule{
      api_version: rule_map["apiVersion"],
      kind: rule_map["kind"],
      namespace: rule_map["namespace"],
      reason: rule_map["reason"],
      message: rule_map["message"],
      type: rule_map["type"],
      labels: rule_map["labels"] || %{},
      annotations: rule_map["annotations"] || %{},
      min_count: rule_map["minCount"] || 0,
      component: rule_map["component"],
      host: rule_map["host"],
      receiver: rule_map["receiver"]
    }
  end

  defp parse_sub_routes(nil), do: []

  defp parse_sub_routes(routes) when is_list(routes) do
    Enum.map(routes, fn route_map ->
      %Kubesee.Route{
        drop: parse_rules(route_map["drop"]),
        match: parse_rules(route_map["match"]),
        routes: parse_sub_routes(route_map["routes"])
      }
    end)
  end

  defp parse_leader_election(nil) do
    {:ok, %Kubesee.Config.LeaderElection{enabled: false, leader_election_id: nil}}
  end

  defp parse_leader_election(map) when is_map(map) do
    {:ok,
     %Kubesee.Config.LeaderElection{
       enabled: map["enabled"] || false,
       leader_election_id: map["leaderElectionID"]
     }}
  end
end
