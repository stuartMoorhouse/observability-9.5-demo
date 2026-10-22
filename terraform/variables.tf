variable "aws_region" {
  description = "AWS region for EKS and the Elastic Cloud Hosted deployment"
  type        = string
  default     = "eu-north-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use (set in local.auto.tfvars)"
  type        = string
}

variable "prefix" {
  description = "Resource name prefix"
  type        = string
  default     = "obs95-demo"
}

variable "elastic_cloud_organization" {
  description = "Elastic Cloud organization name, used for naming and as a sanity check against the EC_API_KEY"
  type        = string
}

variable "elastic_version" {
  description = "Elastic Stack version (pin to the latest 9.5.x patch)"
  type        = string
}

variable "alert_email_recipients" {
  description = "Recipients for the SLO burn-rate email connector"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to all AWS resources via default_tags"
  type        = map(string)
  default     = {}
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version (latest in EKS standard support that the kube-stack chart supports)"
  type        = string
  default     = "1.34"
}

variable "kube_stack_chart_version" {
  description = "opentelemetry-kube-stack Helm chart version (Elastic 9.5 docs pin 0.16.0)"
  type        = string
  default     = "0.16.0"
}

variable "image_build_tool" {
  description = "Container build tool used to build and push demo images"
  type        = string
  default     = "docker"
}

variable "image_platform" {
  description = "Target platform for demo images; also selects the EKS node architecture (linux/arm64 = Graviton, linux/amd64 = x86_64)"
  type        = string
  default     = "linux/arm64"

  validation {
    condition     = contains(["linux/arm64", "linux/amd64"], var.image_platform)
    error_message = "image_platform must be linux/arm64 or linux/amd64."
  }
}

variable "loadgen_rate" {
  description = "k6 load generator request rate (req/s)"
  type        = number
  default     = 5
}

variable "eks_api_allowed_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. Empty = only the public IP of the machine running Terraform (re-apply if it changes)."
  type        = list(string)
  default     = []
}

variable "control_panel_allowed_cidrs" {
  description = "CIDRs allowed to reach the demo-control-panel (AWS WAF allowlist on its CloudFront distribution). Empty = only the public IP of the machine running Terraform (re-apply if it changes)."
  type        = list(string)
  default     = []
}
