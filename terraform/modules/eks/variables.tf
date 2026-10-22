variable "prefix" {
  description = "Resource name prefix"
  type        = string
}

variable "aws_region" {
  description = "AWS region for the VPC and EKS cluster"
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI profile used by local-exec provisioners (kubeconfig, VPC cleanup)"
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.34"
}

variable "tags" {
  description = "Tags for EC2 instances, volumes and ENIs launched by the node group (same as the provider default_tags)"
  type        = map(string)
  default     = {}
}

variable "node_architecture" {
  description = "Worker node CPU architecture: arm64 (Graviton) or amd64 (x86_64). Must match the image platform."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "amd64"], var.node_architecture)
    error_message = "node_architecture must be arm64 or amd64."
  }
}

variable "node_instance_types" {
  description = "Instance types for the spot managed node group. null = pick by node_architecture. Several types improve spot availability."
  type        = list(string)
  default     = null
}

variable "node_desired_size" {
  description = "Desired node count"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum node count"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum node count"
  type        = number
  default     = 3
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.95.0.0/16"
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint (root passes the operator IP /32 by default)"
  type        = list(string)
}

variable "node_disk_size_gb" {
  description = "Root EBS volume size for worker nodes (GiB)"
  type        = number
  default     = 30
}
