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

variable "node_instance_types" {
  description = "Instance types for the spot managed node group (x86_64). Several types improve spot availability."
  type        = list(string)
  default     = ["m6i.large", "m7i.large", "m5.large"]
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
