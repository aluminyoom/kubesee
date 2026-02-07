defmodule Kubesee.Sinks.Kafka do
  @moduledoc false

  use GenServer

  require Logger

  @behaviour Kubesee.Sink

  alias Kubesee.Sinks.Common

  @default_client_id "kubesee_kafka"

  @impl Kubesee.Sink
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl Kubesee.Sink
  def send(sink, event) do
    GenServer.call(sink, {:send, event}, 30_000)
  end

  @impl Kubesee.Sink
  def close(sink) do
    GenServer.stop(sink)
  end

  @impl GenServer
  def init(config) do
    topic = config["topic"]
    brokers = parse_brokers(config["brokers"] || [])
    client_id = String.to_atom(config["clientId"] || @default_client_id)
    client_config = build_client_config(config)

    kafka_client = kafka_client_module()

    case kafka_client.start_client(brokers, client_id, client_config) do
      :ok ->
        case kafka_client.start_producer(client_id, topic, []) do
          :ok ->
            Logger.info("kafka: Producer initialized for topic: #{topic}")

            {:ok,
             %{
               config: config,
               topic: topic,
               client_id: client_id,
               kafka_client: kafka_client
             }}

          {:error, reason} ->
            kafka_client.stop_client(client_id)
            {:stop, {:producer_start_failed, reason}}
        end

      {:error, reason} ->
        {:stop, {:client_start_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call({:send, event}, _from, state) do
    result = do_send(event, state)
    {:reply, result, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Logger.info("kafka: Closing producer...")
    state.kafka_client.stop_client(state.client_id)
    :ok
  end

  defp do_send(event, state) do
    case Common.serialize_event(event, state.config) do
      {:ok, body} ->
        key = event.uid || ""

        state.kafka_client.produce_sync(
          state.client_id,
          state.topic,
          :hash,
          key,
          body
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def parse_brokers(brokers) when is_list(brokers) do
    Enum.map(brokers, &parse_broker/1)
  end

  defp parse_broker(broker) when is_binary(broker) do
    case String.split(broker, ":") do
      [host, port_str] ->
        {String.to_charlist(host), String.to_integer(port_str)}

      [host] ->
        {String.to_charlist(host), 9092}
    end
  end

  @doc false
  def build_client_config(config) do
    []
    |> maybe_add_compression(config["compressionCodec"])
    |> maybe_add_ssl(config["tls"])
    |> maybe_add_sasl(config["sasl"])
  end

  defp maybe_add_compression(opts, nil), do: opts
  defp maybe_add_compression(opts, "none"), do: opts

  defp maybe_add_compression(opts, codec) do
    Keyword.put(opts, :compression, compression_codec(codec))
  end

  @doc false
  def compression_codec("snappy"), do: :snappy
  def compression_codec("gzip"), do: :gzip
  def compression_codec("lz4"), do: :lz4
  def compression_codec("zstd"), do: :zstd
  def compression_codec(_), do: :no_compression

  defp maybe_add_ssl(opts, nil), do: opts
  defp maybe_add_ssl(opts, %{"enable" => false}), do: opts

  defp maybe_add_ssl(opts, %{"enable" => true} = tls_config) do
    ssl_opts = build_ssl_options(tls_config)
    Keyword.put(opts, :ssl, ssl_opts)
  end

  defp maybe_add_ssl(opts, _), do: opts

  @doc false
  def build_ssl_options(tls_config) do
    opts = [verify: :verify_peer]

    opts
    |> maybe_add_ssl_opt(tls_config["insecureSkipVerify"], :verify, :verify_none)
    |> maybe_add_ssl_opt(tls_config["caFile"], :cacertfile)
    |> maybe_add_ssl_opt(tls_config["certFile"], :certfile)
    |> maybe_add_ssl_opt(tls_config["keyFile"], :keyfile)
  end

  defp maybe_add_ssl_opt(opts, true, key, value), do: Keyword.put(opts, key, value)
  defp maybe_add_ssl_opt(opts, _flag, _key, _value), do: opts

  defp maybe_add_ssl_opt(opts, value, key) when is_binary(value) and value != "" do
    Keyword.put(opts, key, String.to_charlist(value))
  end

  defp maybe_add_ssl_opt(opts, _value, _key), do: opts

  defp maybe_add_sasl(opts, nil), do: opts
  defp maybe_add_sasl(opts, %{"enable" => false}), do: opts

  defp maybe_add_sasl(opts, %{"enable" => true} = sasl_config) do
    mechanism = sasl_mechanism(sasl_config["mechanism"])
    username = sasl_config["username"] || ""
    password = sasl_config["password"] || ""
    Keyword.put(opts, :sasl, {mechanism, username, password})
  end

  defp maybe_add_sasl(opts, _), do: opts

  @doc false
  def sasl_mechanism("plain"), do: :plain
  def sasl_mechanism("sha256"), do: :scram_sha_256
  def sasl_mechanism("sha512"), do: :scram_sha_512
  def sasl_mechanism(_), do: :plain

  defp kafka_client_module do
    Application.get_env(:kubesee, :kafka_client, Kubesee.KafkaClient.Default)
  end
end
