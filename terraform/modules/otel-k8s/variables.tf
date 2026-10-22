variable "elasticsearch_endpoint" {
  description = "Elasticsearch HTTPS endpoint the EDOT gateway collector exports to (elasticsearch exporter, OTel mapping mode)."
  type        = string

  validation {
    condition     = can(regex("^https://", var.elasticsearch_endpoint))
    error_message = "elasticsearch_endpoint must be an https:// URL."
  }
}

variable "kube_stack_chart_version" {
  description = "opentelemetry-kube-stack Helm chart version. 0.16.0 is the version Elastic tested with the v9.5.5 values file (EDOT ECH Kubernetes quickstart)."
  type        = string
  default     = "0.16.0"
}

variable "elastic_version" {
  description = "Elastic Stack version; used as the EDOT collector image tag (docker.elastic.co/elastic-agent/elastic-agent:<version>). Must be an exact patch, e.g. 9.5.5."
  type        = string

  validation {
    condition     = can(regex("^9\\.[0-9]+\\.[0-9]+$", var.elastic_version))
    error_message = "elastic_version must be an exact 9.x.y version (for example 9.5.5)."
  }
}

variable "namespace" {
  description = "Namespace for the OTel operator, collectors and the Instrumentation CR. The contract (interfaces.md) fixes this to opentelemetry-operator-system."
  type        = string
  default     = "opentelemetry-operator-system"
}

variable "api_key_expiration" {
  description = "Expiration of the collector Elasticsearch API key (Elasticsearch duration, e.g. 90d). Empty string = no expiration."
  type        = string
  default     = "90d"
}

variable "postgres" {
  description = "Demo Postgres connection for the cluster collector's postgresql receiver (endpoint is host:port)."
  type = object({
    username = string
    password = string
    database = string
    endpoint = string
  })
  sensitive = true
}
