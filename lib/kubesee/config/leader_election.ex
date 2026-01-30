defmodule Kubesee.Config.LeaderElection do
  @moduledoc false

  defstruct [:enabled, :leader_election_id]

  @type t :: %__MODULE__{
          enabled: boolean(),
          leader_election_id: String.t() | nil
        }
end
