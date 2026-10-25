variable "prefix" {
  description = "Resource name prefix"
  type        = string
}

variable "deployment_id" {
  description = "Elastic Cloud deployment ID (the S3 client credentials go into its keystore)"
  type        = string
}

variable "ilm_policy_name" {
  description = "ILM policy applied to all logs, metrics and traces data streams"
  type        = string
  default     = "demo-logs"
}

variable "frozen_min_age" {
  description = "Age at which indices move to the frozen tier (searchable snapshot in the S3 repository)"
  type        = string
  default     = "7d"
}

variable "delete_min_age" {
  description = "Age at which indices are deleted"
  type        = string
  default     = "365d"
}
