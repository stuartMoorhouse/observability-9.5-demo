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
  description = "demo-control-panel HTTPS URL (CloudFront default certificate)"
  value       = "https://${aws_cloudfront_distribution.control_panel.domain_name}"
}

output "web_banking_url" {
  description = "web-banking browser UI HTTPS URL (CloudFront default certificate)"
  value       = "https://${aws_cloudfront_distribution.web_banking.domain_name}"
}

output "control_panel_ip_set" {
  description = "Name and ID of the WAF IP set (CLOUDFRONT scope, us-east-1) behind the control panel and bank UI"
  value       = { name = aws_wafv2_ip_set.control_panel.name, id = aws_wafv2_ip_set.control_panel.id }
}
