# Configuration reference

The configuration files and definitions that the `otel-k8s` and `kibana-content` modules deploy. Everything is applied by `terraform apply`. None of these files contain credentials.

## Collection (modules/otel-k8s)

| File / resource | Purpose | Target |
|---|---|---|
| `modules/otel-k8s/values.yaml` | Elastic's kube-stack values for direct Elasticsearch ingestion, copied unchanged from `elastic/elastic-agent` tag `v9.5.5` (`deploy/helm/edot-collector/kube-stack/values.yaml`). It defines the EDOT daemon and gateway collectors, the OTel Operator (auto-generated webhook certs, no cert-manager) and the Instrumentation CR `elastic-instrumentation`. | Helm chart `open-telemetry/opentelemetry-kube-stack` `0.16.0`, release `opentelemetry-kube-stack` in `opentelemetry-operator-system` |
| `helm_release.kube_stack` override | Sets `defaultCRConfig.image.tag` to `var.elastic_version`. | same |
| `elasticstack_elasticsearch_security_api_key.otel` | Collector API key with `auto_configure` and `create_doc` on `logs-*`, `metrics-*` and `traces-*`, plus cluster `monitor`. | `POST /_security/api_key` |
| `kubernetes_secret_v1.elastic` | Secret `elastic-secret-otel` with keys `elastic_endpoint` and `elastic_api_key`, read by the gateway collector. | K8s API |

Data lands in the OTel-native data streams `traces-*.otel-*`, `logs-*.otel-*` and `metrics-*.otel-*`.

## Kibana content (modules/kibana-content)

| File / resource | Purpose | Target |
|---|---|---|
| `main.tf`: data view `banking-traces-otel` | Data view over `traces-*.otel-*`, used by the threshold rules. | Data views API |
| `slo.tf`: SLO `banking-latency` | 99% of transactions take 500 ms or less (`transaction.duration.us <= 500000`). KQL custom SLI, 7d rolling window, occurrences budgeting, grouped by `service.name`. | SLO API `/api/observability/slos` |
| `slo.tf`: SLO `banking-availability` | 99% of transactions have `event.outcome: success`. Same settings as `banking-latency`. | same |
| `rules.tf`: burn-rate rules | One `slo.rules.burnRate` rule per SLO, with windows 15m/5m (14.4x, alert), 1h/5m (6x, high), 6h/30m (3x, medium) and 24h/2h (1x, low). Alert and high send email through `elastic-cloud-email` when `alert_email_recipients` is not empty. | Alerting API `/api/alerting/rule` |
| `rules.tf`: latency rule | `observability.rules.custom_threshold`: p95 `transaction.duration.us` > 500 ms over 5m, grouped by `service.name`. | same |
| `rules.tf`: error-rate rule | `observability.rules.custom_threshold`: failed / total transactions > 5% over 5m, grouped by `service.name`. | same |
| `ml.tf`: job `banking-transaction-latency` | `high_mean(transaction.duration.us)` partitioned by `service.name`, 5m buckets. Its datafeed `datafeed-banking-transaction-latency` filters only on `processor.event` and `deployment.environment`, so new services are picked up automatically. The datafeed is started by Terraform. | ML APIs `/_ml/anomaly_detectors`, `/_ml/datafeeds` |
| `security.tf`: roles and users | `demo-sre`: Observability all, plus `observabilityAIAssistant`, `agentBuilder`, `actions` and `monitor_inference`. `demo-viewer`: Observability read only, with no AI or connector privileges. One user per role, with passwords from `random_password` (sensitive outputs). | Kibana role API, `/_security/user` |
| `dashboards.tf` | Upserts every `dashboards/*.json` when its hash changes. | Dashboards API `PUT /api/dashboards/{id}` |

## Dashboards (dashboards/)

File format, shared with `scripts/export-dashboard.sh`:

```json
{ "id": "<dashboard id>", "data": { "title": "...", "panels": [ ... ], "time_range": { ... } } }
```

Terraform sends `data` as the flat request body of `PUT /api/dashboards/<id>`, with the `kbn-xsrf: true` header. If `id` is missing, the file name without `.json` is used. The body must not contain `id`, `meta` or `spaces`.

| File | Content |
|---|---|
| `dashboards/banking-service-overview.json` | ES\|QL panels showing transactions, p95 latency and error rate, both as totals and per service over time, plus a per-service table. Source: `traces-*.otel-*`, filtered to `deployment.environment == "banking-demo"`. |
| `dashboards/banking-incident-triage.json` | Error logs per service (`severity_number >= 17`), exceptions by `service.version`, a `service.version` breakdown, error rate per service@version, and DB span p95 with the slowest DB spans. |
