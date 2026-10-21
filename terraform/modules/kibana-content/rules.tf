# Alerting rules.
#
# 1. SLO burn-rate rules (rule_type_id slo.rules.burnRate, consumer slo), one per SLO. Params schema verified
#    against Kibana 9.5 source (x-pack/platform/packages/shared/response-ops/rule_params/slo_burn_rate/v1.ts):
#    { sloId, windows: [{ id, burnRateThreshold, maxBurnRateThreshold, longWindow{value,unit},
#    shortWindow{value,unit}, actionGroup }], dependencies }. Action group ids from
#    x-pack/solutions/observability/plugins/slo/common/constants.ts: slo.burnRate.alert|high|medium|low.
#    A grouped SLO yields one alert per service.name instance.
#
# 2. Latency and error-rate threshold rules: custom threshold rule (observability.rules.custom_threshold,
#    params schema rule_params/custom_threshold/v1.ts on 9.5) over the traces data view, grouped by
#    service.name. The APM rule types (apm.transaction_duration / apm.transaction_error_rate) are not used
#    because they query aggregated APM transaction metrics; see main.tf. Group-by service.name means a newly
#    deployed fx-rates is covered automatically.

locals {
  # Burn-rate windows for a 7d SLO window. maxBurnRateThreshold = SLO window / long window (budget fully
  # consumed inside the long window), mirroring what the Kibana rule UI computes.
  slo_window_minutes = 7 * 24 * 60

  burn_rate_windows = [
    { id = "fast-15m", threshold = 14.4, long = 15, short = 5, group = "slo.burnRate.alert" },
    { id = "page-1h", threshold = 6, long = 60, short = 5, group = "slo.burnRate.high" },
    { id = "ticket-6h", threshold = 3, long = 360, short = 30, group = "slo.burnRate.medium" },
    { id = "ticket-24h", threshold = 1, long = 1440, short = 120, group = "slo.burnRate.low" },
  ]

  burn_rate_email_groups = ["slo.burnRate.alert", "slo.burnRate.high"]
}

resource "elasticstack_kibana_alerting_rule" "burn_rate" {
  for_each = elasticstack_kibana_slo.this

  space_id     = var.space_id
  name         = "SLO burn rate: ${each.value.name}"
  consumer     = "slo"
  rule_type_id = "slo.rules.burnRate"
  interval     = "1m"
  enabled      = true

  params = jsonencode({
    sloId = each.value.slo_id
    windows = [for w in local.burn_rate_windows : {
      id                   = w.id
      burnRateThreshold    = w.threshold
      maxBurnRateThreshold = floor(local.slo_window_minutes / w.long)
      longWindow           = { value = w.long, unit = "m" }
      shortWindow          = { value = w.short, unit = "m" }
      actionGroup          = w.group
    }]
    dependencies = []
  })

  dynamic "actions" {
    for_each = local.send_email ? local.burn_rate_email_groups : []
    content {
      id    = var.email_connector_id
      group = actions.value
      params = jsonencode({
        to      = var.alert_email_recipients
        subject = "[banking-demo] {{rule.name}} - {{context.sloInstanceId}}"
        message = <<-EOT
          {{context.reason}}

          SLO: {{context.sloName}} (instance {{context.sloInstanceId}})
          Burn rate (long window): {{context.longWindow.burnRate}}
          Burn rate (short window): {{context.shortWindow.burnRate}}
          Threshold: {{context.burnRateThreshold}}

          SLO details: {{context.viewInAppUrl}}
          Alert details: {{context.alertDetailsUrl}}
        EOT
      })
      frequency {
        summary     = false
        notify_when = "onActionGroupChange"
      }
    }
  }

  tags = concat(local.common_tags, ["slo-burn-rate"])
}

resource "elasticstack_kibana_alerting_rule" "latency" {
  space_id     = var.space_id
  name         = "Banking: p95 transaction latency > ${var.latency_threshold_ms} ms (per service)"
  consumer     = "alerts"
  rule_type_id = "observability.rules.custom_threshold"
  interval     = "1m"
  enabled      = true

  params = jsonencode({
    criteria = [{
      comparator = ">"
      threshold  = [local.latency_threshold_us]
      timeSize   = 5
      timeUnit   = "m"
      metrics = [{
        name    = "A"
        aggType = "p95"
        field   = "transaction.duration.us"
      }]
      equation = "A"
      label    = "p95 transaction.duration.us"
    }]
    groupBy               = ["service.name"]
    alertOnNoData         = false
    alertOnGroupDisappear = false
    searchConfiguration = {
      index = elasticstack_kibana_data_view.traces_otel.data_view.id
      query = {
        language = "kuery"
        query    = local.transaction_filter_kql
      }
    }
  })

  tags = concat(local.common_tags, ["latency"])
}

resource "elasticstack_kibana_alerting_rule" "error_rate" {
  space_id     = var.space_id
  name         = "Banking: transaction error rate > ${var.error_rate_threshold_pct}% (per service)"
  consumer     = "alerts"
  rule_type_id = "observability.rules.custom_threshold"
  interval     = "1m"
  enabled      = true

  params = jsonencode({
    criteria = [{
      comparator = ">"
      threshold  = [var.error_rate_threshold_pct]
      timeSize   = 5
      timeUnit   = "m"
      metrics = [
        {
          name    = "A"
          aggType = "count"
          filter  = "event.outcome: \"failure\""
        },
        {
          name    = "B"
          aggType = "count"
        },
      ]
      equation = "(A / B) * 100"
      label    = "error rate %"
    }]
    groupBy               = ["service.name"]
    alertOnNoData         = false
    alertOnGroupDisappear = false
    searchConfiguration = {
      index = elasticstack_kibana_data_view.traces_otel.data_view.id
      query = {
        language = "kuery"
        query    = local.transaction_filter_kql
      }
    }
  })

  tags = concat(local.common_tags, ["error-rate"])
}
