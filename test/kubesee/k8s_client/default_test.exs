defmodule Kubesee.K8sClient.DefaultTest do
  use ExUnit.Case

  import Mox

  alias Kubesee.K8sClient.Default

  setup :verify_on_exit!

  setup do
    conn = %{test: :conn}
    Application.put_env(:kubesee, :k8s_client_impl, Kubesee.K8sClientMockImpl)
    {:ok, conn: conn}
  end

  describe "watch_events/2" do
    test "returns stream successfully", %{conn: conn} do
      test_stream = [%{"event" => "data"}]
      operation = %K8s.Operation{}

      expect(Kubesee.K8sClientMockImpl, :watch, fn "v1", "Event", [namespace: "default"] ->
        operation
      end)

      expect(Kubesee.K8sClientMockImpl, :stream, fn ^conn, ^operation ->
        {:ok, test_stream}
      end)

      assert {:ok, stream} = Default.watch_events(conn, "default")
      assert stream == test_stream
    end

    test "handles nil namespace (all namespaces)", %{conn: conn} do
      test_stream = [%{"event" => "data"}]
      operation = %K8s.Operation{}

      expect(Kubesee.K8sClientMockImpl, :watch, fn "v1", "Event", [] ->
        operation
      end)

      expect(Kubesee.K8sClientMockImpl, :stream, fn ^conn, ^operation ->
        {:ok, test_stream}
      end)

      assert {:ok, stream} = Default.watch_events(conn, nil)
      assert stream == test_stream
    end

    test "returns error on stream failure", %{conn: conn} do
      operation = %K8s.Operation{}

      expect(Kubesee.K8sClientMockImpl, :watch, fn "v1", "Event", [namespace: "default"] ->
        operation
      end)

      expect(Kubesee.K8sClientMockImpl, :stream, fn ^conn, ^operation ->
        {:error, :connection_failed}
      end)

      assert {:error, :connection_failed} = Default.watch_events(conn, "default")
    end
  end

  describe "get_resource/5" do
    test "returns resource map successfully", %{conn: conn} do
      resource = %{"apiVersion" => "v1", "kind" => "Pod", "metadata" => %{"name" => "test"}}
      operation = %K8s.Operation{}

      expect(Kubesee.K8sClientMockImpl, :get, fn "v1",
                                                 "Pod",
                                                 [name: "test", namespace: "default"] ->
        operation
      end)

      expect(Kubesee.K8sClientMockImpl, :run, fn ^conn, ^operation ->
        {:ok, resource}
      end)

      assert {:ok, result} = Default.get_resource(conn, "v1", "Pod", "default", "test")
      assert result == resource
    end

    test "returns not_found error for missing resource", %{conn: conn} do
      error = %K8s.Client.APIError{reason: "NotFound"}
      operation = %K8s.Operation{}

      expect(Kubesee.K8sClientMockImpl, :get, fn "v1",
                                                 "Pod",
                                                 [name: "test", namespace: "default"] ->
        operation
      end)

      expect(Kubesee.K8sClientMockImpl, :run, fn ^conn, ^operation ->
        {:error, error}
      end)

      assert {:error, :not_found} = Default.get_resource(conn, "v1", "Pod", "default", "test")
    end

    test "returns generic error for other failures", %{conn: conn} do
      error = %K8s.Client.APIError{reason: "InternalError"}
      operation = %K8s.Operation{}

      expect(Kubesee.K8sClientMockImpl, :get, fn "v1",
                                                 "Pod",
                                                 [name: "test", namespace: "default"] ->
        operation
      end)

      expect(Kubesee.K8sClientMockImpl, :run, fn ^conn, ^operation ->
        {:error, error}
      end)

      assert {:error, ^error} = Default.get_resource(conn, "v1", "Pod", "default", "test")
    end

    test "handles connection errors", %{conn: conn} do
      operation = %K8s.Operation{}

      expect(Kubesee.K8sClientMockImpl, :get, fn "v1",
                                                 "Pod",
                                                 [name: "test", namespace: "default"] ->
        operation
      end)

      expect(Kubesee.K8sClientMockImpl, :run, fn ^conn, ^operation ->
        {:error, :connection_timeout}
      end)

      assert {:error, :connection_timeout} =
               Default.get_resource(conn, "v1", "Pod", "default", "test")
    end
  end
end
