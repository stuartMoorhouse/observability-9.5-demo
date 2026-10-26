output "demo_sre_password" {
  description = "Password of the demo-sre user."
  value       = random_password.demo_sre.result
  sensitive   = true
}

output "demo_viewer_password" {
  description = "Password of the demo-viewer user."
  value       = random_password.demo_viewer.result
  sensitive   = true
}

output "slo_id" {
  description = "Id of the transaction latency SLO (grouped by service.name)."
  value       = elasticstack_kibana_slo.this["latency"].slo_id
}

output "availability_slo_id" {
  description = "Id of the transaction availability SLO (grouped by service.name)."
  value       = elasticstack_kibana_slo.this["availability"].slo_id
}

output "burn_rate_rule_id" {
  description = "Rule id of the burn-rate rule on the latency SLO."
  value       = elasticstack_kibana_alerting_rule.burn_rate["latency"].rule_id
}

output "availability_burn_rate_rule_id" {
  description = "Rule id of the burn-rate rule on the availability SLO (raised by the bad release)."
  value       = elasticstack_kibana_alerting_rule.burn_rate["availability"].rule_id
}

output "latency_rule_id" {
  description = "Rule id of the per-service p95 latency threshold rule."
  value       = elasticstack_kibana_alerting_rule.latency.rule_id
}

output "error_rate_rule_id" {
  description = "Rule id of the per-service error-rate threshold rule."
  value       = elasticstack_kibana_alerting_rule.error_rate.rule_id
}

output "ml_job_id" {
  description = "Anomaly detection job id."
  value       = elasticstack_elasticsearch_ml_anomaly_detection_job.latency.job_id
}

output "dashboard_ids" {
  description = "Dashboard ids deployed from dashboards_dir."
  value       = keys(local.dashboards)
}
