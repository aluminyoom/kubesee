defmodule Kubesee.Sinks.Loki do
  @moduledoc false

  use GenServer

  require Logger

  @behaviour Kubesee.Sink

  alias Kubesee.Template

  import Kubesee.Sinks.Common, only: [serialize_event: 2]

  @request_timeout_ms 10_000

  @impl Kubesee.Sink
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl Kubesee.Sink
  def send(sink, event) do
    GenServer.call(sink, {:send, event}, @request_timeout_ms + 5_000)
  end

  @impl Kubesee.Sink
  def close(sink) do
    GenServer.stop(sink)
  end

  @impl GenServer
  def init(config) do
    url = config["url"]
    req_options = build_req_options(url, config["tls"])
    {:ok, %{config: config, req_options: req_options}}
  end

  @impl GenServer
  def handle_call({:send, event}, _from, state) do
    result = do_send(event, state)
    {:reply, result, state}
  end

  defp do_send(event, state) do
    with {:ok, log_line} <- serialize_event(event, state.config),
         {:ok, body} <- build_loki_body(log_line, state.config) do
      headers = build_headers(event, state.config)

      req =
        Req.merge(Req.new(state.req_options),
          body: body,
          headers: headers,
          receive_timeout: @request_timeout_ms
        )

      send_request(req)
    end
  end

  defp build_loki_body(log_line, config) do
    timestamp = generate_timestamp()
    stream_labels = config["streamLabels"] || %{}

    loki_msg = %{
      "streams" => [
        %{
          "stream" => stream_labels,
          "values" => [[timestamp, log_line]]
        }
      ]
    }

    Jason.encode(loki_msg)
  end

  defp send_request(req) do
    case Req.request(req) do
      {:ok, %{status: status}} when status >= 200 and status < 300 ->
        :ok

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_timestamp do
    "#{System.system_time(:second)}000000000"
  end

  defp build_headers(event, config) do
    base_headers = [{"content-type", "application/json"}]
    headers_config = config["headers"] || %{}

    custom_headers =
      Enum.map(headers_config, fn {key, value} ->
        rendered_value = render_header_value(value, event, key)
        {key, rendered_value}
      end)

    base_headers ++ custom_headers
  end

  defp render_header_value(template, event, header_name) do
    case Template.render(template, event) do
      {:ok, value} ->
        value

      {:error, reason} ->
        Logger.debug(
          "Template error for header #{header_name}: #{inspect(reason)}, using raw value"
        )

        template
    end
  end

  defp build_req_options(url, tls_config) do
    base_opts = [url: url, method: :post]

    case build_ssl_options(tls_config) do
      [] -> base_opts
      ssl_opts -> Keyword.put(base_opts, :connect_options, ssl: ssl_opts)
    end
  end

  defp build_ssl_options(nil), do: []

  defp build_ssl_options(tls_config) do
    []
    |> maybe_add_ssl_opt(tls_config["insecureSkipVerify"], :verify, :verify_none)
    |> maybe_add_ssl_opt(tls_config["caFile"], :cacertfile)
    |> maybe_add_ssl_opt(tls_config["certFile"], :certfile)
    |> maybe_add_ssl_opt(tls_config["keyFile"], :keyfile)
  end

  defp maybe_add_ssl_opt(opts, true, key, value), do: [{key, value} | opts]
  defp maybe_add_ssl_opt(opts, _flag, _key, _value), do: opts

  defp maybe_add_ssl_opt(opts, value, key) when is_binary(value), do: [{key, value} | opts]
  defp maybe_add_ssl_opt(opts, _value, _key), do: opts
end
