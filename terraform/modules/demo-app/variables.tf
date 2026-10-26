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

variable "kibana_url" {
  description = "Kibana URL for the control panel's deep links"
  type        = string
}

variable "control_panel_allowed_cidrs" {
  description = "IPv4 CIDRs allowed through the AWS WAF on the demo-control-panel and web-banking CloudFront distributions"
  type        = list(string)

  validation {
    condition     = length(var.control_panel_allowed_cidrs) > 0 && !contains(var.control_panel_allowed_cidrs, "0.0.0.0/0")
    error_message = "control_panel_allowed_cidrs must list at least one CIDR and must not include 0.0.0.0/0."
  }
}

variable "tags" {
  description = "Org tags applied to the control panel and web-banking load balancers (created by Kubernetes, outside provider default_tags)"
  type        = map(string)
  default     = {}
}

variable "postgres" {
  description = "Postgres credentials written to the postgres-credentials secret (generated in the root module)"
  type = object({
    username = string
    password = string
    database = string
  })
  sensitive = true
}
