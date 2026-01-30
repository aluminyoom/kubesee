defmodule Kubesee.K8sConn do
  @moduledoc """
  Kubernetes connection bootstrap module.
  
  Auto-detects the Kubernetes environment and establishes a connection.
  """

  require Logger

  @doc """
  Establishes a connection to Kubernetes.
  
  Attempts to connect to Kubernetes in the following order:
  1. In-cluster: Uses service account if running in a pod
  2. KUBECONFIG: Uses kubeconfig file specified by KUBECONFIG env var
  3. Default: Uses ~/.kube/config as fallback
  
  Returns `{:ok, K8s.Conn.t()}` on success or `{:error, reason}` on failure.
  """
  @spec connect() :: {:ok, K8s.Conn.t()} | {:error, String.t()}
  def connect do
    service_account_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"

    if file_impl().exists?(service_account_path) do
      connect_in_cluster()
    else
      connect_out_of_cluster()
    end
  end

  defp connect_in_cluster do
    Logger.debug("Attempting in-cluster Kubernetes connection")

    case k8s_conn_impl().from_service_account() do
      {:ok, conn} ->
        Logger.info("Successfully connected to Kubernetes using service account")
        {:ok, conn}

      {:error, reason} ->
        Logger.error("Failed to connect to Kubernetes using service account: #{inspect(reason)}")
        {:error, "Failed to load in-cluster credentials: #{inspect(reason)}"}
    end
  end

  defp connect_out_of_cluster do
    Logger.debug("Attempting out-of-cluster Kubernetes connection")

    kubeconfig_path = env_impl().get("KUBECONFIG") || default_kubeconfig_path()

    case k8s_conn_impl().from_file(kubeconfig_path) do
      {:ok, conn} ->
        Logger.info("Successfully connected to Kubernetes using #{kubeconfig_path}")
        {:ok, conn}

      {:error, reason} ->
        Logger.error("Failed to connect to Kubernetes using #{kubeconfig_path}: #{inspect(reason)}")
        {:error, "No kubernetes configuration found"}
    end
  end

  defp default_kubeconfig_path do
    home = System.get_env("HOME", "~")
    Path.join(home, ".kube/config")
  end

  # Dependency injection for testability
  defp file_impl do
    Application.get_env(:kubesee, :file_impl, Kubesee.FileImpl)
  end

  defp env_impl do
    Application.get_env(:kubesee, :env_impl, Kubesee.EnvImpl)
  end

  defp k8s_conn_impl do
    Application.get_env(:kubesee, :k8s_conn_impl, Kubesee.K8sConnImpl)
  end
end
