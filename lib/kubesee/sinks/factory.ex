defmodule Kubesee.Sinks.Factory do
  @moduledoc false

  alias Kubesee.Config.Receiver

  @spec create(Receiver.t()) :: {:ok, pid()} | {:error, term()}
  def create(%Receiver{sink_type: sink_type, sink_config: config}) do
    case sink_module(sink_type) do
      {:ok, module} -> module.start_link(config || %{})
      {:error, _} = error -> error
    end
  end

  defp sink_module(:stdout), do: {:ok, Kubesee.Sinks.Stdout}
  defp sink_module(:file), do: {:ok, Kubesee.Sinks.File}
  defp sink_module(:webhook), do: {:ok, Kubesee.Sinks.Webhook}
  defp sink_module(:pipe), do: {:ok, Kubesee.Sinks.Pipe}
  defp sink_module(:in_memory), do: {:ok, Kubesee.Sinks.InMemory}
  defp sink_module(other), do: {:error, {:unsupported_sink, other}}
end
