variable "prefix" {
  description = "Name prefix; ECR repositories are created as <prefix>/<service>"
  type        = string
}

variable "aws_region" {
  description = "AWS region for ECR"
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI profile used for ECR login and image existence checks"
  type        = string
}

variable "instrumentation_ref" {
  description = "OTel Operator Instrumentation CR referenced by the inject-* pod annotations (<namespace>/<name>)"
  type        = string
}

variable "image_build_tool" {
  description = "Container CLI used to build and push images (docker or podman)"
  type        = string
  default     = "docker"
}

variable "image_platform" {
  description = "Target platform for image builds (must match the EKS node architecture)"
  type        = string
  default     = "linux/arm64"
}

variable "app_version" {
  description = "service.version reported by all demo services"
  type        = string
  default     = "1.4.2"
}

variable "loadgen_rate" {
  description = "k6 load generator request rate (requests per second)"
  type        = number
  default     = 5
}
