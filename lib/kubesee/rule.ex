defmodule Kubesee.Rule do
  @moduledoc false

  alias Kubesee.Event

  defstruct [
    :labels,
    :annotations,
    :message,
    :api_version,
    :kind,
    :namespace,
    :reason,
    :type,
    :min_count,
    :component,
    :host,
    :receiver
  ]

  @type t :: %__MODULE__{
          labels: map() | nil,
          annotations: map() | nil,
          message: String.t() | nil,
          api_version: String.t() | nil,
          kind: String.t() | nil,
          namespace: String.t() | nil,
          reason: String.t() | nil,
          type: String.t() | nil,
          min_count: non_neg_integer() | nil,
          component: String.t() | nil,
          host: String.t() | nil,
          receiver: String.t() | nil
        }

  @doc """
  Checks if the rule matches the given event.

  All fields are compared as regular expressions. An empty/nil pattern matches anything.
  For labels and annotations, all specified keys must be present and their values must match.
  """
  @spec matches?(t(), Event.t()) :: boolean()
  def matches?(%__MODULE__{} = rule, %Event{} = event) do
    basic_fields_match?(rule, event) &&
      labels_match?(rule.labels, event.involved_object.labels) &&
      annotations_match?(rule.annotations, event.involved_object.annotations) &&
      count_matches?(rule.min_count, event.count)
  end

  defp basic_fields_match?(rule, event) do
    rules = [
      {rule.message, event.message},
      {rule.api_version, get_in_or_nil(event, [:involved_object, :api_version])},
      {rule.kind, get_in_or_nil(event, [:involved_object, :kind])},
      {rule.namespace, event.namespace},
      {rule.reason, event.reason},
      {rule.type, event.type},
      {rule.component, get_in_or_nil(event, [:source, :component])},
      {rule.host, get_in_or_nil(event, [:source, :host])}
    ]

    Enum.all?(rules, fn {pattern, value} ->
      pattern_matches?(pattern, value)
    end)
  end

  defp get_in_or_nil(struct, keys) do
    Enum.reduce_while(keys, struct, fn key, acc ->
      case acc do
        nil -> {:halt, nil}
        %{} -> {:cont, Map.get(acc, key)}
        _ -> {:halt, nil}
      end
    end)
  end

  defp pattern_matches?(nil, _value), do: true
  defp pattern_matches?("", _value), do: true

  defp pattern_matches?(pattern, value) when is_binary(pattern) do
    value_str = value || ""
    regex_match?(pattern, value_str)
  end

  defp regex_match?(pattern, value) do
    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, value)
      {:error, _} -> false
    end
  end

  defp labels_match?(nil, _event_labels), do: true
  defp labels_match?(rule_labels, _event_labels) when rule_labels == %{}, do: true

  defp labels_match?(rule_labels, event_labels) when is_map(rule_labels) do
    event_labels = event_labels || %{}

    Enum.all?(rule_labels, fn {key, pattern} ->
      case Map.fetch(event_labels, key) do
        {:ok, value} -> regex_match?(pattern, value)
        :error -> false
      end
    end)
  end

  defp annotations_match?(nil, _event_annotations), do: true

  defp annotations_match?(rule_annotations, _event_annotations) when rule_annotations == %{},
    do: true

  defp annotations_match?(rule_annotations, event_annotations) when is_map(rule_annotations) do
    event_annotations = event_annotations || %{}

    Enum.all?(rule_annotations, fn {key, pattern} ->
      case Map.fetch(event_annotations, key) do
        {:ok, value} -> regex_match?(pattern, value)
        :error -> false
      end
    end)
  end

  defp count_matches?(nil, _count), do: true
  defp count_matches?(0, _count), do: true
  defp count_matches?(min_count, count), do: (count || 1) >= min_count
end
