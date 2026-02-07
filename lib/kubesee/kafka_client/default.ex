defmodule Kubesee.KafkaClient.Default do
  @moduledoc false
  @behaviour Kubesee.KafkaClient

  @impl true
  def start_client(brokers, client_id, config) do
    :brod.start_client(brokers, client_id, config)
  end

  @impl true
  def start_producer(client_id, topic, config) do
    :brod.start_producer(client_id, topic, config)
  end

  @impl true
  def produce_sync(client_id, topic, partition, key, value) do
    :brod.produce_sync(client_id, topic, partition, key, value)
  end

  @impl true
  def stop_client(client_id) do
    :brod.stop_client(client_id)
  end
end
