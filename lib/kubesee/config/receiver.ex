defmodule Kubesee.Config.Receiver do
  @moduledoc false

  defstruct [:name, :sink_type, :sink_config]

  @type t :: %__MODULE__{
          name: String.t(),
          sink_type: atom(),
          sink_config: map()
        }
end
