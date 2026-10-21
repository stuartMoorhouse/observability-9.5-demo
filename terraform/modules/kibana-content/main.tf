# Kibana content for the banking demo.
#
# Data model decision (applies to slo.tf, rules.tf, ml.tf, dashboards):
# The demo services are instrumented by EDOT SDKs via the OTel Operator and shipped by the EDOT gateway
# collector with the elasticsearch exporter in `mapping: mode: otel`. Spans therefore land in the OTel-native
# data streams `traces-*.otel-*` (LogsDB), not in classic `traces-apm*` / `metrics-apm*`.
#
# The gateway runs the `elasticapm` processor, which enriches every span with the classic APM fields as span
# attributes (source: elastic/opentelemetry-collector-components processor/elasticapmprocessor/internal/
# enrichments/span.go): processor.event ("transaction" | "span"), transaction.duration.us, transaction.name,
# transaction.type, event.outcome, span.duration.us, span.type/subtype, service.target.*. The OTel index
# templates expose `attributes.*` and `resource.attributes.*` as passthrough fields, so these (and
# service.name, service.version, deployment.environment) are queryable by their ECS-style top-level names.
#
# We therefore define SLIs and threshold rules directly on `traces-*.otel-*` with KQL instead of the APM
# SLI types (sli.apm.transactionDuration / transactionErrorRate) and the APM rule types
# (apm.transaction_duration / apm.transaction_error_rate). Those read pre-aggregated transaction metrics
# (`transaction.duration.histogram`, metricset.name: transaction) from the APM index settings; whether the
# elasticapm connector's `metrics-*.1m.otel-*` output is fully equivalent for those SLI/rule types on 9.5 is
# not stated in the 9.5 docs, while the raw-span approach is fully under our control and works the same for
# every service, including fx-rates deployed later.

locals {
  # Base KQL filter shared by SLOs, threshold rules and the ML datafeed: service entry spans only,
  # scoped to the demo environment.
  transaction_filter_kql = "processor.event: \"transaction\" and deployment.environment: \"${var.environment}\""

  latency_threshold_us = var.latency_threshold_ms * 1000

  common_tags = ["banking-demo", "terraform"]

  send_email = length(var.alert_email_recipients) > 0
}

# Data view over the OTel-native traces. Used by the custom threshold rules (searchConfiguration.index) and
# handy in Discover. allow_no_index lets Terraform create it before the first span arrives.
resource "elasticstack_kibana_data_view" "traces_otel" {
  space_id = var.space_id
  override = true

  data_view = {
    id              = "banking-traces-otel"
    name            = "Banking demo traces (OTel)"
    title           = var.traces_index_pattern
    time_field_name = "@timestamp"
    allow_no_index  = true
  }
}
