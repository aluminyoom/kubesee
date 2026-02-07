defmodule Kubesee.Sinks.OpenSearch do
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

  @doc """
  Formats an index name by replacing Go date format patterns within curly braces.

  Go reference time components:
  - `2006` → 4-digit year
  - `01` → 2-digit month
  - `02` → 2-digit day
  - `15` → 2-digit hour (24h)
  - `04` → 2-digit minute
  - `05` → 2-digit second
  """
  def format_index_name(pattern, datetime) do
    Regex.replace(~r/\{([^}]+)\}/, pattern, fn _match, format ->
      format_go_date(format, datetime)
    end)
  end

  # GenServer callbacks

  @impl GenServer
  def init(config) do
    host = config |> Map.get("hosts", []) |> List.first() || "http://localhost:9200"
    req_options = build_req_options(host, config)
    {:ok, %{config: config, req_options: req_options}}
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
        url = build_url(event, state.config)
        params = build_query_params(state.config)

        req =
          Req.merge(Req.new(state.req_options),
            url: url,
            body: body,
            params: params,
            headers: [{"content-type", "application/json"}],
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

  defp build_url(event, config) do
    index = resolve_index(config)
    doc_id = resolve_doc_id(event, config)

    case doc_id do
      nil -> "/#{index}/_doc"
      id -> "/#{index}/_doc/#{id}"
    end
  end

  defp resolve_index(config) do
    index_format = Map.get(config, "indexFormat")

    if is_binary(index_format) and index_format != "" do
      format_index_name(index_format, DateTime.utc_now())
    else
      Map.get(config, "index", "kube-events")
    end
  end

  defp resolve_doc_id(event, %{"useEventID" => true}), do: event.uid
  defp resolve_doc_id(_event, _config), do: nil

  defp build_query_params(config) do
    case Map.get(config, "type") do
      nil -> []
      "" -> []
      type -> [type: type]
    end
  end

  defp build_req_options(host, config) do
    base_opts = [base_url: host, method: :post]

    base_opts
    |> maybe_add_auth(config)
    |> maybe_add_ssl(config["tls"])
  end

  defp maybe_add_auth(opts, %{"username" => username, "password" => password})
       when is_binary(username) and is_binary(password) do
    Keyword.put(opts, :auth, {:basic, "#{username}:#{password}"})
  end

  defp maybe_add_auth(opts, _config), do: opts

  defp maybe_add_ssl(opts, nil), do: opts

  defp maybe_add_ssl(opts, tls_config) do
    ssl_opts =
      []
      |> maybe_add_ssl_opt(tls_config["insecureSkipVerify"], :verify, :verify_none)
      |> maybe_add_ssl_opt(tls_config["caFile"], :cacertfile)
      |> maybe_add_ssl_opt(tls_config["certFile"], :certfile)
      |> maybe_add_ssl_opt(tls_config["keyFile"], :keyfile)

    case ssl_opts do
      [] -> opts
      _ -> Keyword.put(opts, :connect_options, ssl: ssl_opts)
    end
  end

  defp maybe_add_ssl_opt(opts, true, key, value), do: [{key, value} | opts]
  defp maybe_add_ssl_opt(opts, _flag, _key, _value), do: opts

  defp maybe_add_ssl_opt(opts, value, key) when is_binary(value), do: [{key, value} | opts]
  defp maybe_add_ssl_opt(opts, _value, _key), do: opts

  defp format_go_date(format, datetime) do
    # Use placeholder-based replacement to avoid ordering conflicts.
    # Go reference time: 2006-01-02 15:04:05
    # We must replace longer/more-specific patterns first, then use unique
    # placeholders to prevent partial matches.
    format
    |> String.replace("2006", "\x001")
    |> String.replace("01", "\x002")
    |> String.replace("02", "\x003")
    |> String.replace("15", "\x004")
    |> String.replace("04", "\x005")
    |> String.replace("05", "\x006")
    |> String.replace("\x001", String.pad_leading("#{datetime.year}", 4, "0"))
    |> String.replace("\x002", String.pad_leading("#{datetime.month}", 2, "0"))
    |> String.replace("\x003", String.pad_leading("#{datetime.day}", 2, "0"))
    |> String.replace("\x004", String.pad_leading("#{datetime.hour}", 2, "0"))
    |> String.replace("\x005", String.pad_leading("#{datetime.minute}", 2, "0"))
    |> String.replace("\x006", String.pad_leading("#{datetime.second}", 2, "0"))
  end
end
