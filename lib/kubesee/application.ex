defmodule Kubesee.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    config_file = System.get_env("KUBESEE_CONFIG")

    case config_file do
      nil ->
        if Application.get_env(:kubesee, :start_engine, true) do
          raise "KUBESEE_CONFIG environment variable not set. Please set it to the path of your kubesee config file."
        else
          start_minimal_supervisor()
        end

      _ ->
        start_with_config(config_file)
    end
  end

  defp start_minimal_supervisor do
    children = []
    opts = [strategy: :one_for_one, name: Kubesee.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp start_with_config(config_file) do
    with {:ok, yaml_string} <- read_config_file(config_file),
         {:ok, config} <- parse_config(yaml_string),
         {:ok, conn} <- connect_kubernetes() do
      config = %{config | conn: conn}
      start_supervisor(config)
    end
  end

  defp read_config_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> raise "Failed to read config file #{path}: #{inspect(reason)}"
    end
  end

  defp parse_config(yaml_string) do
    case Kubesee.Config.parse(yaml_string) do
      {:ok, config} -> {:ok, config}
      {:error, reason} -> raise "Failed to parse config: #{reason}"
    end
  end

  defp connect_kubernetes do
    k8s_conn_impl = Application.get_env(:kubesee, :k8s_conn, Kubesee.K8sConn)

    case k8s_conn_impl.connect() do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> raise "Failed to connect to Kubernetes: #{reason}"
    end
  end

  defp start_supervisor(config) do
    children = build_children(config)
    opts = [strategy: :one_for_one, name: Kubesee.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp build_children(config) do
    if Application.get_env(:kubesee, :start_engine, true) do
      [Supervisor.child_spec({Kubesee.Engine, config}, id: Kubesee.Engine)]
    else
      []
    end
  end
end
