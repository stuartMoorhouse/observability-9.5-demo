# Machine learning: one anomaly detection job over all services' transaction latency.
#
# high_mean(transaction.duration.us) partitioned by service.name models each service separately inside a single
# job, so fx-rates gets its own model as soon as it sends transactions (spec scenario 1). The datafeed reads the
# raw OTel-native spans (see main.tf); `transaction.duration.us` is the elasticapm processor enrichment.
#
# Native elasticstack resources (provider >= 0.16.x): job -> job_state(opened) -> datafeed -> datafeed_state(started).

locals {
  ml_job_id      = "banking-transaction-latency"
  ml_datafeed_id = "datafeed-banking-transaction-latency"
}

resource "elasticstack_elasticsearch_ml_anomaly_detection_job" "latency" {
  job_id      = local.ml_job_id
  description = "Transaction latency anomalies per service.name in ${var.environment} (OTel-native traces)"
  groups      = ["banking-demo"]

  analysis_config = {
    bucket_span = var.ml_bucket_span
    detectors = [
      {
        function             = "high_mean"
        field_name           = "transaction.duration.us"
        partition_field_name = "service.name"
        detector_description = "High mean transaction.duration.us partitioned by service.name"
      }
    ]
    influencers = ["service.name", "service.version", "transaction.name"]
  }

  analysis_limits = {
    model_memory_limit = "64mb"
  }

  data_description = {
    time_field = "@timestamp"
  }

  model_plot_config = {
    enabled = true
  }

  results_retention_days = 14
  allow_lazy_open        = true
}

resource "elasticstack_elasticsearch_ml_job_state" "latency" {
  job_id = elasticstack_elasticsearch_ml_anomaly_detection_job.latency.job_id
  state  = "opened"
}

resource "elasticstack_elasticsearch_ml_datafeed" "latency" {
  datafeed_id = local.ml_datafeed_id
  job_id      = elasticstack_elasticsearch_ml_anomaly_detection_job.latency.job_id
  indices     = [var.traces_index_pattern]

  query = jsonencode({
    bool = {
      filter = [
        { term = { "processor.event" = "transaction" } },
        { term = { "deployment.environment" = var.environment } },
      ]
    }
  })

  # The traces data streams may not exist yet when Terraform runs.
  indices_options = {
    allow_no_indices   = true
    ignore_unavailable = true
  }

  query_delay = "60s"
  frequency   = "60s"
}

resource "elasticstack_elasticsearch_ml_datafeed_state" "latency" {
  datafeed_id = elasticstack_elasticsearch_ml_datafeed.latency.datafeed_id
  state       = "started"

  depends_on = [elasticstack_elasticsearch_ml_job_state.latency]
}
