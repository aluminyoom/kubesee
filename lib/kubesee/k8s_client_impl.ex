defmodule Kubesee.K8sClientImpl.Behaviour do
  @moduledoc """
  Behaviour for K8s.Client operations. Allows mocking in tests.
  """

  @callback watch(api_version :: String.t(), kind :: String.t(), opts :: Keyword.t()) ::
              K8s.Client.t()

  @callback get(api_version :: String.t(), kind :: String.t(), opts :: Keyword.t()) ::
              K8s.Client.t()

  @callback stream(conn :: K8s.Conn.t(), operation :: K8s.Client.t()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @callback run(conn :: K8s.Conn.t(), operation :: K8s.Client.t()) ::
              {:ok, map()} | {:error, term()}
end

defmodule Kubesee.K8sClientImpl do
  @moduledoc """
  Default implementation of K8s.Client operations.
  """

  @behaviour Kubesee.K8sClientImpl.Behaviour

  @impl true
  def watch(api_version, kind, opts) do
    K8s.Client.watch(api_version, kind, opts)
  end

  @impl true
  def get(api_version, kind, opts) do
    K8s.Client.get(api_version, kind, opts)
  end

  @impl true
  def stream(conn, operation) do
    K8s.Client.stream(conn, operation)
  end

  @impl true
  def run(conn, operation) do
    K8s.Client.run(conn, operation)
  end
end
