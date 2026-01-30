defmodule Kubesee.K8sConnTest do
  use ExUnit.Case

  alias Kubesee.K8sConn

  setup do
    # Configure test app to use mock implementations
    Application.put_env(:kubesee, :file_impl, Kubesee.FileImpl)
    Application.put_env(:kubesee, :env_impl, Kubesee.EnvImpl)
    Application.put_env(:kubesee, :k8s_conn_impl, Kubesee.K8sConnImpl)

    :ok
  end

  describe "connect/0" do
    test "returns error when no kubeconfig available" do
      Mox.expect(Kubesee.FileImpl, :exists?, fn path ->
        path == "/var/run/secrets/kubernetes.io/serviceaccount/token" && false
      end)

      Mox.expect(Kubesee.EnvImpl, :get, fn "KUBECONFIG" -> nil end)

      home = System.get_env("HOME")
      default_path = Path.join(home, ".kube/config")

      Mox.expect(Kubesee.K8sConnImpl, :from_file, fn path ->
        if path == default_path, do: {:error, :enoent}, else: {:error, :unexpected_args}
      end)

      assert {:error, msg} = K8sConn.connect()
      assert msg =~ "No kubernetes configuration found"
    end

    test "uses service account when in-cluster token exists" do
      Mox.expect(Kubesee.FileImpl, :exists?, fn path ->
        path == "/var/run/secrets/kubernetes.io/serviceaccount/token"
      end)

      Mox.expect(Kubesee.K8sConnImpl, :from_service_account, fn ->
        {:ok, :service_account_conn}
      end)

      assert {:ok, conn} = K8sConn.connect()
      assert conn == :service_account_conn
    end

    test "uses KUBECONFIG env var when set" do
      Mox.expect(Kubesee.FileImpl, :exists?, fn path ->
        path == "/var/run/secrets/kubernetes.io/serviceaccount/token" && false
      end)

      Mox.expect(Kubesee.EnvImpl, :get, fn "KUBECONFIG" ->
        "/custom/kubeconfig.yaml"
      end)

      Mox.expect(Kubesee.K8sConnImpl, :from_file, fn path ->
        if path == "/custom/kubeconfig.yaml", do: {:ok, :env_config_conn}, else: {:error, :unexpected_args}
      end)

      assert {:ok, conn} = K8sConn.connect()
      assert conn == :env_config_conn
    end

    test "uses default ~/.kube/config as fallback" do
      Mox.expect(Kubesee.FileImpl, :exists?, fn path ->
        path == "/var/run/secrets/kubernetes.io/serviceaccount/token" && false
      end)

      Mox.expect(Kubesee.EnvImpl, :get, fn "KUBECONFIG" ->
        nil
      end)

      home = System.get_env("HOME")
      default_path = Path.join(home, ".kube/config")

      Mox.expect(Kubesee.K8sConnImpl, :from_file, fn path ->
        if path == default_path, do: {:ok, :default_config_conn}, else: {:error, :unexpected_args}
      end)

      assert {:ok, conn} = K8sConn.connect()
      assert conn == :default_config_conn
    end

    test "returns error when KUBECONFIG file not found" do
      Mox.expect(Kubesee.FileImpl, :exists?, fn path ->
        path == "/var/run/secrets/kubernetes.io/serviceaccount/token" && false
      end)

      Mox.expect(Kubesee.EnvImpl, :get, fn "KUBECONFIG" ->
        "/nonexistent/kubeconfig.yaml"
      end)

      Mox.expect(Kubesee.K8sConnImpl, :from_file, fn path ->
        if path == "/nonexistent/kubeconfig.yaml", do: {:error, :enoent}, else: {:error, :unexpected_args}
      end)

      assert {:error, _msg} = K8sConn.connect()
    end

    test "returns error when default kubeconfig not found" do
      Mox.expect(Kubesee.FileImpl, :exists?, fn path ->
        path == "/var/run/secrets/kubernetes.io/serviceaccount/token" && false
      end)

      Mox.expect(Kubesee.EnvImpl, :get, fn "KUBECONFIG" ->
        nil
      end)

      home = System.get_env("HOME")
      default_path = Path.join(home, ".kube/config")

      Mox.expect(Kubesee.K8sConnImpl, :from_file, fn path ->
        if path == default_path, do: {:error, :enoent}, else: {:error, :unexpected_args}
      end)

      assert {:error, msg} = K8sConn.connect()
      assert msg =~ "No kubernetes configuration found"
    end

    test "returns error when service account load fails" do
      Mox.expect(Kubesee.FileImpl, :exists?, fn path ->
        path == "/var/run/secrets/kubernetes.io/serviceaccount/token"
      end)

      Mox.expect(Kubesee.K8sConnImpl, :from_service_account, fn ->
        {:error, :permission_denied}
      end)

      assert {:error, _msg} = K8sConn.connect()
    end
  end
end
