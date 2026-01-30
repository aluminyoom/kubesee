defmodule Kubesee.Sink do
  @moduledoc false

  @callback start_link(config :: map()) :: GenServer.on_start()
  @callback send(sink :: pid(), event :: Kubesee.Event.t()) :: :ok | {:error, term()}
  @callback close(sink :: pid()) :: :ok
end
