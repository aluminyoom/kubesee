# kubesee

kubernetes event exporter in elixir - export k8s cluster events to multiple sinks for observability, alerting, and analysis.

## overview

kubesee watches kubernetes cluster events and exports them to configurable sinks. it is a feature-compatible elixir implementation of [kubernetes-event-exporter](https://github.com/resmoio/kubernetes-event-exporter).

### supported sinks

| sink | status | description |
|------|--------|-------------|
| stdout | planned | console output |
| file | planned | write events to file |
| webhook | planned | http/https endpoints |
| pipe | planned | external process stdin |
| elasticsearch | planned | elasticsearch/opensearch |
| opensearch | planned | opensearch clusters |
| kafka | planned | apache kafka topics |
| loki | planned | grafana loki |
| syslog | planned | syslog servers |
| kinesis | planned | aws kinesis streams |
| firehose | planned | aws firehose |
| sqs | planned | aws sqs queues |
| sns | planned | aws sns topics |
| eventbridge | planned | aws eventbridge |
| opscenter | planned | aws systems manager opscenter |
| pubsub | planned | google cloud pub/sub |
| bigquery | planned | google bigquery |
| slack | planned | slack channels |
| teams | planned | microsoft teams |
| opsgenie | planned | opsgenie alerts |

## installation

### from source

```bash
git clone https://github.com/aluminyoom/kubesee.git
cd kubesee
mix deps.get
mix compile
```

### docker

```bash
docker build -t kubesee:latest .
```

## configuration

kubesee uses yaml configuration compatible with kubernetes-event-exporter:

```yaml
logLevel: info
maxEventAgeSeconds: 5
route:
  routes:
    - match:
        - receiver: stdout
receivers:
  - name: stdout
    stdout: {}
```

### environment variables

| variable | default | description |
|----------|---------|-------------|
| `KUBESEE_CONFIG` | `./config.yaml` | config file path |
| `KUBESEE_METRICS_ADDRESS` | `:2112` | metrics endpoint |
| `KUBESEE_METRICS_PREFIX` | `kubesee_` | prometheus metric prefix |
| `KUBESEE_LOG_LEVEL` | `info` | log level override |
| `KUBESEE_KUBECONFIG` | - | explicit kubeconfig path |

## development

### prerequisites

- elixir 1.17+
- erlang/otp 26+

### running tests

```bash
mix test
```

### code quality

```bash
mix format
mix credo --strict
```

## license

apache license 2.0 - see [license](LICENSE) for details.

## acknowledgments

- [kubernetes-event-exporter](https://github.com/resmoio/kubernetes-event-exporter) - original go implementation
