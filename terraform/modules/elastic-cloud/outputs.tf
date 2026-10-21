output "deployment_id" {
  description = "Elastic Cloud deployment ID"
  value       = ec_deployment.this.id
}

output "elasticsearch_endpoint" {
  description = "Elasticsearch HTTPS endpoint"
  value       = ec_deployment.this.elasticsearch.https_endpoint
}

output "kibana_endpoint" {
  description = "Kibana HTTPS endpoint"
  value       = ec_deployment.this.kibana.https_endpoint
}

output "elasticsearch_username" {
  description = "Elastic superuser name"
  value       = ec_deployment.this.elasticsearch_username
}

output "elasticsearch_password" {
  description = "Elastic superuser password"
  value       = ec_deployment.this.elasticsearch_password
  sensitive   = true
}

output "elastic_version" {
  description = "Resolved exact stack version (e.g. 9.5.5) of the deployment"
  value       = ec_deployment.this.version
}
