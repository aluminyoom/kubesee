defmodule Kubesee.Route do
  @moduledoc false

  alias Kubesee.Event
  alias Kubesee.Rule

  defstruct drop: [], match: [], routes: []

  @type t :: %__MODULE__{
          drop: [Rule.t()],
          match: [Rule.t()],
          routes: [t()]
        }

  @doc """
  Processes an event through the route tree.

  First checks drop rules - if any match, the event is dropped and processing stops.
  Then checks match rules - for each matching rule with a receiver, sends to that receiver.
  If all match rules are satisfied, recursively processes sub-routes.

  The send_fn is called with (receiver_name, event) for each matched receiver.
  """
  @spec process_event(t(), Event.t(), (String.t(), Event.t() -> any())) :: :ok
  def process_event(%__MODULE__{} = route, %Event{} = event, send_fn)
      when is_function(send_fn, 2) do
    if should_drop?(route.drop, event) do
      :ok
    else
      matches_all = process_matches(route.match, event, send_fn)

      if matches_all do
        process_sub_routes(route.routes, event, send_fn)
      end

      :ok
    end
  end

  defp should_drop?(drop_rules, event) do
    Enum.any?(drop_rules, fn rule ->
      Rule.matches?(rule, event)
    end)
  end

  defp process_matches(match_rules, event, send_fn) do
    Enum.reduce(match_rules, true, fn rule, matches_all ->
      if Rule.matches?(rule, event) do
        maybe_send_to_receiver(rule, event, send_fn)
        matches_all
      else
        false
      end
    end)
  end

  defp maybe_send_to_receiver(%{receiver: receiver}, event, send_fn)
       when is_binary(receiver) and receiver != "" do
    send_fn.(receiver, event)
  end

  defp maybe_send_to_receiver(_, _, _), do: :ok

  defp process_sub_routes(sub_routes, event, send_fn) do
    Enum.each(sub_routes, fn sub_route ->
      process_event(sub_route, event, send_fn)
    end)
  end
end
