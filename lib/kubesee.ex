defmodule Kubesee do
  @moduledoc false

  def version do
    :kubesee
    |> Application.spec(:vsn)
    |> to_string()
  end
end
