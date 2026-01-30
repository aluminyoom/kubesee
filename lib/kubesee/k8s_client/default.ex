defmodule Kubesee.K8sClient.Default do
  @moduledoc """
  Default implementation of the K8sClient behaviour.

  Uses K8s.Client library to interact with Kubernetes API.
  Supports dependency injection for K8s.Client functions via Application config.
  """

  @behaviour Kubesee.K8sClient

  require Logger

  @impl true
  def watch_events(conn, namespace) do
    opts = build_namespace_opts(namespace)
    operation = k8s_client_impl().watch("v1", "Event", opts)
    k8s_client_impl().stream(conn, operation)
  end

  @impl true
  def get_resource(conn, api_version, kind, namespace, name) do
    opts = [name: name, namespace: namespace]
    operation = k8s_client_impl().get(api_version, kind, opts)

    case k8s_client_impl().run(conn, operation) do
      {:ok, resource} ->
        {:ok, resource}

      {:error, %K8s.Client.APIError{reason: "NotFound"}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Dependency injection for testability
  defp k8s_client_impl do
    Application.get_env(:kubesee, :k8s_client_impl, Kubesee.K8sClientImpl)
  end

  defp build_namespace_opts(nil), do: []
  defp build_namespace_opts(namespace), do: [namespace: namespace]
end
