# SLOs (Kibana SLO API via elasticstack_kibana_slo).
#
# Both SLOs span every service in deployment.environment = var.environment and are grouped by service.name,
# so transfer-service gets its own SLO instance, and so does fx-rates as soon as it sends its first span
# (spec scenario 1) without any Kibana change.
#
# SLI type: KQL custom indicator (sli.kql.custom) over traces-*.otel-* - see main.tf for why the APM SLI
# types are not used with OTel-native data.
#
# Window/budget: 7d rolling, occurrences budgeting, 99 % target. With the burn-rate windows in rules.tf
# (fastest: 5m long / 1m short at 14.4x) a fault that makes ~all transactions bad crosses the threshold
# after ~45 s of bad data in the long window; adding SLO transform frequency (1m) + sync delay (1m) and
# the 1m rule interval gives an expected detection delay of ~4 min (measured 235-260 s).

locals {
  slos = {
    latency = {
      slo_id      = "banking-latency"
      name        = "Banking transaction latency (${var.latency_threshold_ms} ms)"
      description = "${var.slo_target * 100}% of service transactions in ${var.environment} complete in ${var.latency_threshold_ms} ms or less. One instance per service.name."
      good        = "transaction.duration.us <= ${local.latency_threshold_us}"
      total       = "transaction.duration.us >= 0"
    }
    availability = {
      slo_id      = "banking-availability"
      name        = "Banking transaction availability"
      description = "${var.slo_target * 100}% of service transactions in ${var.environment} succeed (event.outcome success). One instance per service.name."
      good        = "event.outcome: \"success\""
      total       = "event.outcome: (\"success\" or \"failure\")"
    }
  }
}

resource "elasticstack_kibana_slo" "this" {
  for_each = local.slos

  space_id    = var.space_id
  slo_id      = each.value.slo_id
  name        = each.value.name
  description = each.value.description

  kql_custom_indicator {
    index           = var.traces_index_pattern
    timestamp_field = "@timestamp"
    filter          = local.transaction_filter_kql
    good            = each.value.good
    total           = each.value.total
  }

  group_by         = ["service.name"]
  budgeting_method = "occurrences"

  time_window {
    duration = "7d"
    type     = "rolling"
  }

  objective {
    target = var.slo_target
  }

  settings {
    frequency                = "1m"
    sync_delay               = "1m"
    prevent_initial_backfill = true
  }

  tags = concat(local.common_tags, ["slo-${each.key}"])
}
