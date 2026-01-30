defmodule Kubesee.K8sConnBehaviour do
  @moduledoc false

  @callback connect() :: {:ok, term()} | {:error, String.t()}
end
