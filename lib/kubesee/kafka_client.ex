defmodule Kubesee.KafkaClient do
  @moduledoc false

  @callback start_client(brokers :: list(), client_id :: atom(), config :: keyword()) ::
              :ok | {:error, term()}
  @callback start_producer(client_id :: atom(), topic :: String.t(), config :: keyword()) ::
              :ok | {:error, term()}
  @callback produce_sync(
              client_id :: atom(),
              topic :: String.t(),
              partition :: atom(),
              key :: binary(),
              value :: binary()
            ) :: :ok | {:error, term()}
  @callback stop_client(client_id :: atom()) :: :ok
end
