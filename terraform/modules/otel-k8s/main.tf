# EDOT on Kubernetes, following "Quickstart for Kubernetes on Elastic Cloud Hosted"
# (https://www.elastic.co/docs/solutions/observability/get-started/opentelemetry/quickstart/ech/k8s),
# section "Using the elasticsearch exporter":
#   1. namespace opentelemetry-operator-system
#   2. secret elastic-secret-otel with keys elastic_endpoint / elastic_api_key
#   3. helm install opentelemetry-kube-stack (chart 0.16.0) with Elastic's v9.5.5 values.yaml
#
# The elasticsearch-exporter path (not the Managed OTLP Endpoint path) is used because the module contract
# (interfaces.md) takes an Elasticsearch endpoint and fixes the secret keys to elastic_endpoint/elastic_api_key.
# Data lands in OTel-native data streams: traces-*.otel-*, logs-*.otel-*, metrics-*.otel-*.
#
# Operator webhook TLS: the Elastic values set
#   opentelemetry-operator.admissionWebhooks.certManager.enabled=false
#   opentelemetry-operator.admissionWebhooks.autoGenerateCert.enabled=true
# so cert-manager is NOT required (Helm generates a self-signed cert for the webhook).
#
# CRD ordering: the kube-stack chart ships the opentelemetry.io CRDs in the `otel-crds` subchart `crds/`
# directory (values `crds.create: true`), which Helm installs before rendering templates. The
# Instrumentation CR (elastic-instrumentation) and OpenTelemetryCollector CRs are therefore created in the
# same release with no separate CRD step. `wait = true` blocks until the operator and collectors are ready
# so modules that annotate pods (demo-app) only start afterwards.
#
# EKS note: the API server must reach the operator webhook on the node (port 9443). The eks module's node
# security group must allow ingress from the cluster security group on 9443 (terraform-aws-modules/eks
# "recommended rules" cover this).

locals {
  instrumentation_name = "elastic-instrumentation"
  secret_name          = "elastic-secret-otel"
}

resource "kubernetes_namespace_v1" "otel" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# Minimal write privileges for the elasticsearch exporter in OTel mapping mode. The EDOT docs only publish
# role descriptors for the Managed OTLP Endpoint (apm application event:write); for direct ingestion the
# collector needs to auto-create and append to the OTel-native data streams.
resource "elasticstack_elasticsearch_security_api_key" "otel" {
  name       = "edot-kube-stack-${var.namespace}"
  expiration = var.api_key_expiration == "" ? null : var.api_key_expiration

  role_descriptors = jsonencode({
    edot_collector_writer = {
      cluster = ["monitor"]
      indices = [
        {
          names      = ["logs-*", "metrics-*", "traces-*"]
          privileges = ["auto_configure", "create_doc"]
        }
      ]
    }
  })

  metadata = jsonencode({
    purpose    = "EDOT gateway collector (opentelemetry-kube-stack)"
    managed_by = "terraform"
  })
}

resource "kubernetes_secret_v1" "elastic" {
  metadata {
    name      = local.secret_name
    namespace = kubernetes_namespace_v1.otel.metadata[0].name
  }

  type = "Opaque"

  data = {
    elastic_endpoint = var.elasticsearch_endpoint
    elastic_api_key  = elasticstack_elasticsearch_security_api_key.otel.encoded
  }
}

# Read by the cluster collector's postgresql receiver (env vars in values.yaml). A copy in this
# namespace because secretKeyRef cannot reach across namespaces.
resource "kubernetes_secret_v1" "postgres" {
  metadata {
    name      = "postgres-credentials"
    namespace = kubernetes_namespace_v1.otel.metadata[0].name
  }

  type = "Opaque"

  data = var.postgres
}

resource "helm_release" "kube_stack" {
  name       = "opentelemetry-kube-stack"
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-kube-stack"
  version    = var.kube_stack_chart_version
  namespace  = kubernetes_namespace_v1.otel.metadata[0].name

  values = [file("${path.module}/values.yaml")]

  # Keep the EDOT collector image in lock-step with the pinned stack version.
  set = [
    {
      name  = "defaultCRConfig.image.tag"
      value = var.elastic_version
    }
  ]

  wait            = true
  timeout         = 900
  atomic          = false
  cleanup_on_fail = true
  max_history     = 5

  # Secret must exist before the collectors start, otherwise pods crash-loop on missing env.
  depends_on = [kubernetes_secret_v1.elastic, kubernetes_secret_v1.postgres]
}
