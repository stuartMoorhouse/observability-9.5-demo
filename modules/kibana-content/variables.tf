variable "kibana_endpoint" {
  description = "Kibana HTTPS endpoint (used by the dashboard deploy step that calls the Dashboards API)."
  type        = string

  validation {
    condition     = can(regex("^https://", var.kibana_endpoint))
    error_message = "kibana_endpoint must be an https:// URL."
  }
}

variable "elasticsearch_endpoint" {
  description = "Elasticsearch HTTPS endpoint. Informational: all Elasticsearch resources use the root-configured elasticstack provider."
  type        = string
}

variable "elastic_username" {
  description = "Kibana user for the Dashboards API calls (elastic superuser from the elastic-cloud module)."
  type        = string
}

variable "elastic_password" {
  description = "Password for elastic_username. Passed to curl only through the environment, never on the command line."
  type        = string
  sensitive   = true
}

variable "alert_email_recipients" {
  description = "Recipients of SLO burn-rate emails. Empty list = rules are created without an email action."
  type        = list(string)
  default     = []
}

variable "environment" {
  description = "deployment.environment value set on every service via OTEL_RESOURCE_ATTRIBUTES."
  type        = string
  default     = "banking-demo"
}

variable "dashboards_dir" {
  description = "Directory with dashboards-as-code JSON files (Dashboards API PUT body; file name without .json = dashboard id)."
  type        = string
}

variable "email_connector_id" {
  description = "Connector id used for burn-rate emails. elastic-cloud-email is the Elastic Cloud preconfigured email connector (Elastic-Cloud-SMTP)."
  type        = string
  default     = "elastic-cloud-email"
}

variable "space_id" {
  description = "Kibana space for SLOs, rules, data view and dashboards."
  type        = string
  default     = "default"
}

variable "traces_index_pattern" {
  description = "OTel-native traces data streams written by the EDOT collector (elasticsearch exporter, mapping mode otel)."
  type        = string
  default     = "traces-*.otel-*"
}

variable "latency_threshold_ms" {
  description = "Latency SLO: a transaction is good when its duration is at or below this value. Also the p95 threshold of the latency rule."
  type        = number
  default     = 500
}

variable "error_rate_threshold_pct" {
  description = "Error-rate rule fires when failed transactions exceed this percentage per service over the rule window."
  type        = number
  default     = 5
}

variable "slo_target" {
  description = "SLO objective (fraction of good events) for both SLOs."
  type        = number
  default     = 0.99
}

variable "ml_bucket_span" {
  description = "Bucket span of the latency anomaly detection job. 5m keeps detection demo-friendly."
  type        = string
  default     = "5m"
}
