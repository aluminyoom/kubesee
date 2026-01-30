defmodule Kubesee.K8sClient do
  @moduledoc false

  @callback watch_events(conn :: term(), namespace :: String.t() | nil) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @callback get_resource(
              conn :: term(),
              api_version :: String.t(),
              kind :: String.t(),
              namespace :: String.t(),
              name :: String.t()
            ) ::
              {:ok, map()} | {:error, :not_found} | {:error, term()}
end
