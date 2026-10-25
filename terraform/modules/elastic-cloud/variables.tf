variable "prefix" {
  description = "Resource name prefix, used as the deployment name"
  type        = string
}

variable "aws_region" {
  description = "AWS region (e.g. eu-north-1); the ECH region is aws-<aws_region>"
  type        = string
}

variable "elastic_version" {
  description = "Stack version: exact (e.g. 9.5.2) or 9.5.x for the latest 9.5 patch"
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.([0-9]+|x)$", var.elastic_version))
    error_message = "elastic_version must look like 9.5.2 or 9.5.x."
  }
}

variable "elastic_cloud_organization" {
  description = "Elastic Cloud organization name (informational tag and sanity check; the EC_API_KEY selects the org)"
  type        = string
}

variable "tags" {
  description = "Tags applied to the deployment"
  type        = map(string)
  default     = {}
}

variable "deployment_template_id" {
  description = "ECH deployment template. Fallbacks if unavailable in the region: aws-storage-optimized, aws-cpu-optimized."
  type        = string
  default     = "aws-general-purpose"
}

variable "hot_size" {
  description = "Hot tier memory per zone"
  type        = string
  default     = "4g"
}

variable "frozen_size" {
  description = "Frozen tier memory (single zone, autoscaling off)"
  type        = string
  default     = "4g"
}

variable "ml_size" {
  description = "Dedicated ML node memory (single zone, autoscaling off)"
  type        = string
  default     = "4g"
}

variable "kibana_size" {
  description = "Kibana memory per zone"
  type        = string
  default     = "1g"
}
