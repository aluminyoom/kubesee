defmodule Kubesee.Sinks.Common do
  @moduledoc false

  alias Kubesee.Event
  alias Kubesee.Template

  @spec maybe_dedot(Event.t(), map()) :: Event.t()
  def maybe_dedot(event, %{"deDot" => true}), do: Event.dedot(event)
  def maybe_dedot(event, _config), do: event

  @spec serialize_event(Event.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def serialize_event(event, %{"layout" => layout}) when is_map(layout) do
    case Template.convert_layout(layout, event) do
      {:ok, result} -> Jason.encode(result)
      {:error, _} = error -> error
    end
  end

  def serialize_event(event, _config) do
    Jason.encode(event)
  end
end
