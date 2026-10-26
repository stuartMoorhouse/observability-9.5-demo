output "kibana_url" {
  description = "Kibana URL"
  value       = module.elastic_cloud.kibana_endpoint
}

output "elasticsearch_url" {
  description = "Elasticsearch URL"
  value       = module.elastic_cloud.elasticsearch_endpoint
}

output "elastic_username" {
  description = "Elastic superuser name"
  value       = module.elastic_cloud.elasticsearch_username
}

output "elastic_password" {
  description = "Elastic superuser password"
  value       = module.elastic_cloud.elasticsearch_password
  sensitive   = true
}

output "deployment_id" {
  description = "Elastic Cloud deployment ID"
  value       = module.elastic_cloud.deployment_id
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

output "aws_profile" {
  description = "AWS CLI profile used by scripts"
  value       = var.aws_profile
}

output "demo_namespace" {
  description = "Kubernetes namespace of the demo app"
  value       = module.demo_app.namespace
}

output "fx_rates_image" {
  description = "fx-rates image URI:tag for scripts/onboard-service.sh"
  value       = module.demo_app.fx_rates_image
}

output "control_panel_url" {
  description = "demo-control-panel HTTPS URL (CloudFront), reachable only from control_panel_allowed_cidrs"
  value       = module.demo_app.control_panel_url
}

output "web_banking_url" {
  description = "web-banking browser UI HTTPS URL (CloudFront, RUM-instrumented), reachable only from control_panel_allowed_cidrs"
  value       = module.demo_app.web_banking_url
}

output "demo_sre_password" {
  description = "Password for the demo-sre Kibana user"
  value       = module.kibana_content.demo_sre_password
  sensitive   = true
}

output "demo_viewer_password" {
  description = "Password for the demo-viewer Kibana user"
  value       = module.kibana_content.demo_viewer_password
  sensitive   = true
}

output "slo_id" {
  description = "SLO ID"
  value       = module.kibana_content.slo_id
}

output "availability_slo_id" {
  description = "Availability SLO ID"
  value       = module.kibana_content.availability_slo_id
}

output "burn_rate_rule_id" {
  description = "SLO burn-rate rule ID"
  value       = module.kibana_content.burn_rate_rule_id
}

output "latency_rule_id" {
  description = "Latency threshold rule ID"
  value       = module.kibana_content.latency_rule_id
}

output "snapshot_bucket" {
  description = "S3 bucket backing the demo-s3-repo snapshot repository"
  value       = module.data_lifecycle.bucket_name
}

output "ilm_policy" {
  description = "ILM policy applied to all logs, metrics and traces"
  value       = module.data_lifecycle.ilm_policy
}
