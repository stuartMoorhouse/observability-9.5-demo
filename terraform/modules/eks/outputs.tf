output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_ca_certificate" {
  description = "EKS cluster CA certificate (PEM, base64-decoded)"
  value       = base64decode(module.eks.cluster_certificate_authority_data)
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "node_role_arn" {
  description = "IAM role ARN of the managed node group"
  value       = module.eks.eks_managed_node_groups["default"].iam_role_arn
}
