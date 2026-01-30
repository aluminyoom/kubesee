defmodule Kubesee.ApplicationTest do
  use ExUnit.Case, async: false

  setup do
    original_config = System.get_env("KUBESEE_CONFIG")
    System.delete_env("KUBESEE_CONFIG")

    pid = Process.whereis(Kubesee.Supervisor)

    if is_pid(pid) and Process.alive?(pid) do
      Supervisor.stop(pid, :normal)
      Process.sleep(10)
    end

    on_exit(fn ->
      pid = Process.whereis(Kubesee.Supervisor)

      if is_pid(pid) and Process.alive?(pid) do
        Supervisor.stop(pid, :normal)
      end

      if original_config do
        System.put_env("KUBESEE_CONFIG", original_config)
      else
        System.delete_env("KUBESEE_CONFIG")
      end
    end)

    :ok
  end

  describe "Application.start/2" do
    test "fails with clear error when KUBESEE_CONFIG env var not set" do
      System.delete_env("KUBESEE_CONFIG")
      Application.put_env(:kubesee, :start_engine, true)

      assert_raise RuntimeError, ~r/KUBESEE_CONFIG environment variable not set/, fn ->
        Kubesee.Application.start(:normal, [])
      end

      Application.put_env(:kubesee, :start_engine, false)
    end

    test "reads config file path from KUBESEE_CONFIG env var" do
      config_file =
        Path.join(System.tmp_dir(), "test_kubesee_config_#{:rand.uniform(1_000_000)}.yaml")

      config_yaml = """
      logLevel: info
      maxEventAgeSeconds: 5
      receivers:
        - name: stdout
          stdout: {}
      route:
        routes:
          - match:
              - receiver: stdout
      """

      File.write!(config_file, config_yaml)

      on_exit(fn ->
        if File.exists?(config_file), do: File.rm!(config_file)
      end)

      System.put_env("KUBESEE_CONFIG", config_file)

      Mox.expect(Kubesee.K8sConnMock, :connect, fn ->
        {:ok, :test_conn}
      end)

      {:ok, sup_pid} = Kubesee.Application.start(:normal, [])
      assert is_pid(sup_pid)

      children = Supervisor.which_children(sup_pid)

      assert Enum.empty?(children) or
               not Enum.any?(children, fn {id, _, _, _} -> id == Kubesee.Engine end)
    end

    test "fails with clear error when config file doesn't exist" do
      nonexistent_file = "/tmp/nonexistent_kubesee_config_#{:rand.uniform(1_000_000)}.yaml"
      System.put_env("KUBESEE_CONFIG", nonexistent_file)

      assert_raise RuntimeError, ~r/Failed to read config file/, fn ->
        Kubesee.Application.start(:normal, [])
      end
    end

    test "fails with clear error when config is invalid YAML" do
      config_file =
        Path.join(System.tmp_dir(), "test_kubesee_invalid_#{:rand.uniform(1_000_000)}.yaml")

      File.write!(config_file, "invalid: yaml: content: [")

      on_exit(fn ->
        if File.exists?(config_file), do: File.rm!(config_file)
      end)

      System.put_env("KUBESEE_CONFIG", config_file)

      assert_raise RuntimeError, ~r/Failed to parse config/, fn ->
        Kubesee.Application.start(:normal, [])
      end
    end

    test "fails with clear error when K8s connection fails" do
      config_file =
        Path.join(System.tmp_dir(), "test_kubesee_k8s_fail_#{:rand.uniform(1_000_000)}.yaml")

      config_yaml = """
      logLevel: info
      maxEventAgeSeconds: 5
      receivers:
        - name: stdout
          stdout: {}
      route:
        routes:
          - match:
              - receiver: stdout
      """

      File.write!(config_file, config_yaml)

      on_exit(fn ->
        if File.exists?(config_file), do: File.rm!(config_file)
      end)

      System.put_env("KUBESEE_CONFIG", config_file)

      Mox.expect(Kubesee.K8sConnMock, :connect, fn ->
        {:error, "No kubernetes configuration found"}
      end)

      assert_raise RuntimeError, ~r/Failed to connect to Kubernetes/, fn ->
        Kubesee.Application.start(:normal, [])
      end
    end

    test "skips engine start in test environment when start_engine is false" do
      config_file =
        Path.join(System.tmp_dir(), "test_kubesee_no_engine_#{:rand.uniform(1_000_000)}.yaml")

      config_yaml = """
      logLevel: info
      maxEventAgeSeconds: 5
      receivers:
        - name: stdout
          stdout: {}
      route:
        routes:
          - match:
              - receiver: stdout
      """

      File.write!(config_file, config_yaml)

      on_exit(fn ->
        if File.exists?(config_file), do: File.rm!(config_file)
      end)

      System.put_env("KUBESEE_CONFIG", config_file)

      Mox.expect(Kubesee.K8sConnMock, :connect, fn ->
        {:ok, :test_conn}
      end)

      {:ok, sup_pid} = Kubesee.Application.start(:normal, [])
      assert is_pid(sup_pid)

      if Application.get_env(:kubesee, :start_engine, true) == false do
        children = Supervisor.which_children(sup_pid)
        refute Enum.any?(children, fn {id, _, _, _} -> id == Kubesee.Engine end)
      end
    end
  end
end
