defmodule Kubesee.EnvImpl.Behaviour do
  @moduledoc """
  Behaviour for environment variable access. Allows mocking in tests.
  """

  @callback get(name :: String.t()) :: String.t() | nil
end

defmodule Kubesee.EnvImpl do
  @moduledoc """
  Default implementation of environment variable access.
  """

  @behaviour Kubesee.EnvImpl.Behaviour

  @impl true
  def get(name) do
    System.get_env(name)
  end
end
