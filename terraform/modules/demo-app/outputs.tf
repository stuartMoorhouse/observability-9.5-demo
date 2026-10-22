output "namespace" {
  description = "Kubernetes namespace of the demo app"
  value       = kubernetes_namespace_v1.banking.metadata[0].name
}

output "ecr_repository_urls" {
  description = "ECR repository URL per service"
  value       = { for svc, repo in aws_ecr_repository.app : svc => repo.repository_url }
}

output "fx_rates_image" {
  description = "fx-rates image (repo:tag), built and pushed but deployed only by scripts/onboard-service.sh"
  value       = "${aws_ecr_repository.app["fx-rates"].repository_url}:${local.image_tag["fx-rates"]}"
  depends_on  = [null_resource.image]
}

output "release_revision" {
  description = "Helm revision of the demo app; known only once the release is deployed and pods are ready (wait = true)"
  value       = helm_release.demo_app.metadata.revision
}

output "control_panel_url" {
  description = "demo-control-panel URL (load balancer DNS; allow 1-3 min after creation for DNS)"
  value       = "http://${data.kubernetes_service_v1.demo_control_panel.status[0].load_balancer[0].ingress[0].hostname}"
}
