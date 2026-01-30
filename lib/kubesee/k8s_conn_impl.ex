defmodule Kubesee.K8sConnImpl.Behaviour do
  @moduledoc """
  Behaviour for K8s.Conn operations. Allows mocking in tests.
  """

  @callback from_service_account() :: {:ok, K8s.Conn.t()} | {:error, term()}
  @callback from_file(path :: String.t()) :: {:ok, K8s.Conn.t()} | {:error, term()}
end

defmodule Kubesee.K8sConnImpl do
  @moduledoc """
  Default implementation of K8s.Conn operations.
  """

  @behaviour Kubesee.K8sConnImpl.Behaviour

  @impl true
  def from_service_account do
    K8s.Conn.from_service_account()
  end

  @impl true
  def from_file(path) do
    K8s.Conn.from_file(path)
  end
end
