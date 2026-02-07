# kubesee

> [!IMPORTANT]
> this project is in its **very early stages**, and it will take a bit of time for it to reach feature parity with kubernetes-event-exporter.
>
> why does this exist? because kubernetes-event-exporter hasn't been updated in a long time and i got tired of trying to make it work also so i can get rid of bitnami
> for real though, you should use [fluent-bit for k8 events](https://docs.fluentbit.io/manual/data-pipeline/filters/kubernetes) if you're not using it already

kubernetes event exporter in elixir basically export k8s cluster events to multiple sinks for observability, alerting, and analysis.

a feature-compatible elixir implementation of [kubernetes-event-exporter](https://github.com/resmoio/kubernetes-event-exporter), built on OTP for reliability and concurrency.

## why

- the original go exporter hasn't been actively maintained
- OTP supervision trees give you self-healing event pipelines for free
- per-sink bounded queues with configurable concurrency so no more dropped events from one slow sink blocking everything
- yaml config is a best effort attempt to making it 1:1 compatible with the go version

## supported sinks

| sink | status | description |
|------|--------|-------------|
| stdout | done | console output (json) |
| file | done | json lines with log rotation (maxsize/maxage/maxbackups) |
| webhook | done | http/https with retries, tls, template headers |
| pipe | done | write to file descriptors or named pipes |
| elasticsearch | partial | indexing with dynamic index names, basic/apikey auth |
| opensearch | partial | same as elasticsearch, separate module |
| kafka | partial | brod-based producer with tls, sasl, compression |
| loki | done | grafana loki push api with stream labels |
| syslog | done | tcp/udp syslog (rfc 3164) |
| kinesis | partial | aws kinesis streams |
| firehose | partial | aws firehose delivery streams |
| sqs | planned | aws sqs queues |
| sns | planned | aws sns topics |
| eventbridge | planned | aws eventbridge |
| opscenter | planned | aws systems manager opscenter |
| pubsub | planned | google cloud pub/sub |
| bigquery | planned | google bigquery |
| slack | planned | slack channels |
| teams | planned | microsoft teams |
| opsgenie | planned | opsgenie alerts |

## quick start

### from source

```bash
git clone https://github.com/aluminyoom/kubesee.git
cd kubesee
mix deps.get
mix compile
```

### run locally

```bash
# create a config file
cat > config.yaml << 'EOF'
logLevel: info
maxEventAgeSeconds: 60
route:
  routes:
    - match:
        - receiver: stdout
receivers:
  - name: stdout
    stdout: {}
EOF

# run (requires kubeconfig)
KUBESEE_CONFIG=./config.yaml mix run --no-halt
```

### docker

```bash
docker build -t kubesee:latest .
docker run -v ~/.kube:/root/.kube -v ./config.yaml:/etc/kubesee/config.yaml kubesee:latest
```

## configuration

kubesee uses yaml configuration compatible with kubernetes-event-exporter. the config structure is identical so you can use your existing config files.

### environment variables

| variable | default | description |
|----------|---------|-------------|
| `KUBESEE_CONFIG` | `./config.yaml` (dev) `/etc/kubesee/config.yaml` (release) | config file path |
| `KUBESEE_LOG_LEVEL` | `info` | log level override |

### full config example

```yaml
logLevel: info
logFormat: json
maxEventAgeSeconds: 60
clusterName: my-cluster
namespace: ""  # empty = all namespaces
kubeQPS: 100
kubeBurst: 500
metricsNamePrefix: kubesee_

route:
  # main route - all events go to dump
  routes:
    - match:
        - receiver: dump
    # drop test namespace events, send critical ones to alerting
    - drop:
        - namespace: "*test*"
        - type: "Normal"
      match:
        - receiver: critical-events

receivers:
  - name: dump
    stdout:
      deDot: true
  - name: critical-events
    webhook:
      endpoint: "https://alerts.example.com/events"
      headers:
        X-API-KEY: "${API_KEY}"
```

### routing

- `match` rules are **exclusive (all conditions must match)**
- `drop` rules execute first to filter events before matching
- match rules within a route are independent 
- an event can match multiple rules
- routes form a tree 
- matched events flow down subtrees

### using secrets

reference environment variables with `${VAR}` syntax:

```yaml
receivers:
  - name: alerts
    webhook:
      endpoint: "https://api.example.com"
      headers:
        Authorization: "Bearer ${API_TOKEN}"
```

`$$` escapes to a literal `$`.

## sink configuration

### stdout

```yaml
receivers:
  - name: dump
    stdout:
      deDot: true       # replace dots in label/annotation keys with underscores
      layout:           # optional custom output format
        message: "{{ .Message }}"
        reason: "{{ .Reason }}"
```

### file

```yaml
receivers:
  - name: file-out
    file:
      path: /var/log/k8s-events.jsonl
      maxsize: 100      # mb before rotation (default 100)
      maxage: 7         # days to retain old files (0 = no limit)
      maxbackups: 3     # max number of rotated files (0 = no limit)
      deDot: true
      layout: {}        # optional
```

rotated files are named `{path}.1`, `{path}.2`, etc.

### webhook

```yaml
receivers:
  - name: alerts
    webhook:
      endpoint: "https://hooks.example.com/events"
      headers:
        X-API-KEY: "${API_KEY}"
        X-Namespace: "{{ .Namespace }}"   # template headers supported
      layout:
        message: "{{ .Message }}"
        kind: "{{ .InvolvedObject.Kind }}"
      tls:
        insecureSkipVerify: false
        caFile: /path/to/ca.crt
        certFile: /path/to/client.crt
        keyFile: /path/to/client.key
```

retries on 429/5xx with exponential backoff

### elasticsearch

```yaml
receivers:
  - name: es
    elasticsearch:
      hosts:
        - https://es-node1:9200
        - https://es-node2:9200
      index: kube-events
      indexFormat: "kube-events-{2006-01-02}"   # go date format for daily indices
      useEventID: true          # use event UID as document ID (enables upsert)
      username: elastic
      password: "${ES_PASSWORD}"
      # or use api key auth:
      # apiKey: "${ES_API_KEY}"
      headers:
        X-Custom: value
      deDot: true
      type: kube-event          # only for ES < 8.0
      tls:
        insecureSkipVerify: false
        caFile: /path/to/ca.crt
      layout: {}                # optional
```

### opensearch

```yaml
receivers:
  - name: os
    opensearch:
      hosts:
        - https://opensearch:9200
      index: kube-events
      indexFormat: "kube-events-{2006-01-02}"
      useEventID: true
      username: admin
      password: "${OS_PASSWORD}"
      deDot: true
      tls:
        insecureSkipVerify: false
        caFile: /path/to/ca.crt
      layout: {}
```

### kafka

```yaml
receivers:
  - name: kafka-out
    kafka:
      topic: kube-events
      brokers:
        - kafka1:9092
        - kafka2:9092
      clientId: kubesee
      compressionCodec: snappy    # none, snappy, gzip, lz4, zstd
      tls:
        enable: true
        caFile: /path/to/ca.crt
        certFile: /path/to/client.crt
        keyFile: /path/to/client.key
        insecureSkipVerify: false
      sasl:
        enable: true
        mechanism: sha256         # plain, sha256, sha512
        username: "${KAFKA_USER}"
        password: "${KAFKA_PASS}"
      layout:
        kind: "{{ .InvolvedObject.Kind }}"
        namespace: "{{ .InvolvedObject.Namespace }}"
        name: "{{ .InvolvedObject.Name }}"
        reason: "{{ .Reason }}"
        message: "{{ .Message }}"
        type: "{{ .Type }}"
        createdAt: "{{ .GetTimestampISO8601 }}"
```

events are partitioned by event UID.

### loki

```yaml
receivers:
  - name: loki-out
    loki:
      url: http://loki:3100/loki/api/v1/push
      headers:
        X-Scope-OrgID: my-tenant    # multi-tenancy
      streamLabels:
        job: kubernetes-events
        cluster: my-cluster
      tls:
        insecureSkipVerify: false
        caFile: /path/to/ca.crt
      layout: {}                    # optional
```

### syslog

```yaml
receivers:
  - name: syslog-out
    syslog:
      network: tcp          # tcp or udp
      address: "syslog:514"
      tag: k8s.event
```

### pipe

```yaml
receivers:
  - name: pipe-out
    pipe:
      path: /dev/stdout     # or a named pipe
      deDot: true
      layout: {}
```

## templates

kubesee supports go-compatible template syntax for layouts and header values.

### field access

```
{{ .Message }}                          # top-level field
{{ .InvolvedObject.Name }}              # nested field
{{ .InvolvedObject.Labels.app }}        # label value
```

### helper methods

```
{{ .GetTimestampMs }}                   # unix timestamp in milliseconds
{{ .GetTimestampISO8601 }}              # ISO 8601 timestamp
```

### sprig functions

| function | example | description |
|----------|---------|-------------|
| `toJson` | `{{ toJson . }}` | json encode |
| `toPrettyJson` | `{{ toPrettyJson . }}` | pretty json encode |
| `upper` | `{{ .Reason \| upper }}` | uppercase |
| `lower` | `{{ .Type \| lower }}` | lowercase |
| `trim` | `{{ .Message \| trim }}` | trim whitespace |
| `quote` | `{{ .Message \| quote }}` | wrap in double quotes |
| `squote` | `{{ .Message \| squote }}` | wrap in single quotes |
| `replace` | `{{ replace "old" "new" .Field }}` | string replace |
| `contains` | `{{ contains "substr" .Field }}` | substring check |
| `hasPrefix` | `{{ hasPrefix "pre" .Field }}` | prefix check |
| `hasSuffix` | `{{ hasSuffix "suf" .Field }}` | suffix check |
| `default` | `{{ default "N/A" .Field }}` | default if empty |
| `empty` | `{{ empty .Field }}` | check if empty |
| `coalesce` | `{{ coalesce .Field1 .Field2 }}` | first non-empty |
| `now` | `{{ now }}` | current iso8601 timestamp |
| `index` | `{{ index .Labels "key" }}` | map/list index access |

### pipes

```
{{ .Message | upper | trim }}
{{ .InvolvedObject.Labels | toJson }}
```

## architecture

```
Kubesee.Application
├── Kubesee.Engine (Supervisor)
│   ├── Kubesee.Registry (GenServer) - per-sink bounded queues + task pools
│   ├── Kubesee.Watcher (GenServer) - k8s event stream consumer
│   └── Kubesee.Sinks.* - sink processes (dynamic)
└── (graceful shutdown: stop watcher -> drain queues -> close sinks)
```

### event flow

```
k8s api -> watcher -> event enrichment -> route tree -> registry -> sink queues -> sink processes
```

- **watcher**: consumes k8s watch stream, filters by age/type, enriches with object metadata (labels, annotations, owner references)
- **route tree**: evaluates match/drop rules, dispatches to receivers
- **registry**: manages per-sink bounded queues (default 1000 events) with configurable concurrency (default 100 workers)
- **backpressure**: when a sink queue is full, new events for that sink return `{:error, :queue_full}` so that other sinks are unaffected

### ordering guarantees

events are enqueued FIFO per sink. with `max_concurrency > 1` (default), delivery order is best-effort. for strict ordering, configure a sink with `max_concurrency: 1` at the cost of throughput.

## development

### prerequisites

- elixir 1.17+
- erlang/otp 26+
- cmake (for kafka nif dependency)

### running tests

```bash
mix test            # 317 tests
mix test --trace    # verbose output (default via alias)
```

### code quality

```bash
mix format
mix credo --strict
mix dialyzer        # static type analysis
```

## license

apache license 2.0 - see [license](LICENSE) for details.

## acknowledgments

- [kubernetes-event-exporter](https://github.com/resmoio/kubernetes-event-exporter) - original go implementation
