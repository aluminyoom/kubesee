defmodule Kubesee.Sinks.Elasticsearch do
  @moduledoc false

  use GenServer

  require Logger

  @behaviour Kubesee.Sink

  import Kubesee.Sinks.Common, only: [maybe_dedot: 2, serialize_event: 2]

  @request_timeout_ms 10_000

  @impl Kubesee.Sink
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl Kubesee.Sink
  def send(sink, event) do
    GenServer.call(sink, {:send, event}, @request_timeout_ms * 2)
  end

  @impl Kubesee.Sink
  def close(sink) do
    GenServer.stop(sink)
  end

  @impl GenServer
  def init(config) do
    host = config |> Map.get("hosts", []) |> List.first() || "http://localhost:9200"
    req_options = build_req_options(host, config)
    {:ok, %{config: config, host: host, req_options: req_options}}
  end

  @impl GenServer
  def handle_call({:send, event}, _from, state) do
    result = do_send(event, state)
    {:reply, result, state}
  end

  defp do_send(event, state) do
    event = maybe_dedot(event, state.config)

    case serialize_event(event, state.config) do
      {:ok, body} ->
        {method, url} = build_url(event, state)
        headers = build_headers(state.config)

        req =
          Req.merge(Req.new(state.req_options),
            method: method,
            url: url,
            body: body,
            headers: headers,
            receive_timeout: @request_timeout_ms
          )

        case Req.request(req) do
          {:ok, %{status: status}} when status >= 200 and status < 300 ->
            :ok

          {:ok, %{status: status}} ->
            {:error, {:http_error, status}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_url(event, state) do
    index = resolve_index(state.config)
    doc_type = state.config["type"]
    use_event_id = state.config["useEventID"]

    base_path =
      if is_binary(doc_type) and doc_type != "" do
        "/#{index}/#{doc_type}/_doc"
      else
        "/#{index}/_doc"
      end

    if use_event_id do
      {:put, state.host <> base_path <> "/#{event.uid}"}
    else
      {:post, state.host <> base_path}
    end
  end

  defp resolve_index(config) do
    index_format = config["indexFormat"]

    if is_binary(index_format) and index_format != "" do
      format_index_name(index_format, DateTime.utc_now())
    else
      config["index"] || "kube-events"
    end
  end

  @doc false
  def format_index_name(pattern, datetime) do
    Regex.replace(~r/\{([^}]+)\}/, pattern, fn _match, format ->
      format_go_date(format, datetime)
    end)
  end

  @go_date_pattern ~r/2006|01|02|15|04|05/

  defp format_go_date(format, datetime) do
    replacements = %{
      "2006" => String.pad_leading("#{datetime.year}", 4, "0"),
      "01" => String.pad_leading("#{datetime.month}", 2, "0"),
      "02" => String.pad_leading("#{datetime.day}", 2, "0"),
      "15" => String.pad_leading("#{datetime.hour}", 2, "0"),
      "04" => String.pad_leading("#{datetime.minute}", 2, "0"),
      "05" => String.pad_leading("#{datetime.second}", 2, "0")
    }

    Regex.replace(@go_date_pattern, format, fn match ->
      Map.fetch!(replacements, match)
    end)
  end

  defp build_headers(config) do
    base = [{"content-type", "application/json"}]

    auth_headers = build_auth_headers(config)
    custom_headers = build_custom_headers(config)

    base ++ auth_headers ++ custom_headers
  end

  defp build_auth_headers(%{"username" => username, "password" => password})
       when is_binary(username) and username != "" do
    encoded = Base.encode64("#{username}:#{password}")
    [{"authorization", "Basic #{encoded}"}]
  end

  defp build_auth_headers(%{"apiKey" => api_key})
       when is_binary(api_key) and api_key != "" do
    [{"authorization", "ApiKey #{api_key}"}]
  end

  defp build_auth_headers(_config), do: []

  defp build_custom_headers(%{"headers" => headers}) when is_map(headers) do
    Enum.map(headers, fn {key, value} -> {key, value} end)
  end

  defp build_custom_headers(_config), do: []

  defp build_req_options(_host, config) do
    base_opts = []

    case build_ssl_options(config["tls"]) do
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
