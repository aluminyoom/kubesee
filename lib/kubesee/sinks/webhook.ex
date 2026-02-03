defmodule Kubesee.Sinks.Webhook do
  @moduledoc false

  use GenServer

  require Logger

  @behaviour Kubesee.Sink

  alias Kubesee.Template

  @max_retries 3
  @base_delay_ms 100
  @request_timeout_ms 10_000
  @retryable_statuses [429, 500, 502, 503, 504]
  @jitter_factor 0.2

  @impl Kubesee.Sink
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl Kubesee.Sink
  def send(sink, event) do
    GenServer.call(sink, {:send, event}, @request_timeout_ms * (@max_retries + 1))
  end

  @impl Kubesee.Sink
  def close(sink) do
    GenServer.stop(sink)
  end

  @impl GenServer
  def init(config) do
    endpoint = config["endpoint"]
    req_options = build_req_options(endpoint, config["tls"])
    {:ok, %{config: config, req_options: req_options}}
  end

  @impl GenServer
  def handle_call({:send, event}, _from, state) do
    result = do_send(event, state)
    {:reply, result, state}
  end

  defp do_send(event, state) do
    case serialize_event(event, state.config) do
      {:ok, body} ->
        headers = build_headers(event, state.config)

        req =
          Req.merge(Req.new(state.req_options),
            body: body,
            headers: headers,
            receive_timeout: @request_timeout_ms
          )

        send_with_retry(req, 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp serialize_event(event, %{"layout" => layout}) when is_map(layout) do
    case Template.convert_layout(layout, event) do
      {:ok, result} -> Jason.encode(result)
      {:error, _} = error -> error
    end
  end

  defp serialize_event(event, _config) do
    Jason.encode(event)
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

  defp send_with_retry(req, attempt) do
    case Req.request(req) do
      {:ok, %{status: status}} when status >= 200 and status < 300 ->
        :ok

      {:ok, %{status: status}} when status in @retryable_statuses ->
        maybe_retry(req, attempt, {:http_error, status})

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        maybe_retry(req, attempt, reason)
    end
  end

  defp maybe_retry(req, attempt, error) do
    if attempt <= @max_retries do
      delay = retry_delay(attempt)
      Process.sleep(delay)
      send_with_retry(req, attempt + 1)
    else
      {:error, error}
    end
  end

  defp retry_delay(attempt) do
    base = round(@base_delay_ms * :math.pow(2, attempt - 1))
    jitter_range = round(base * @jitter_factor * 2)
    jitter = :rand.uniform(jitter_range) - round(base * @jitter_factor)
    base + jitter
  end

  defp build_req_options(endpoint, tls_config) do
    base_opts = [url: endpoint, method: :post]

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
