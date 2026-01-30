defmodule Kubesee.FileImpl.Behaviour do
  @moduledoc """
  Behaviour for file operations. Allows mocking in tests.
  """

  @callback exists?(path :: String.t()) :: boolean()
end

defmodule Kubesee.FileImpl do
  @moduledoc """
  Default implementation of file operations.
  """

  @behaviour Kubesee.FileImpl.Behaviour

  @impl true
  def exists?(path) do
    File.exists?(path)
  end
end
