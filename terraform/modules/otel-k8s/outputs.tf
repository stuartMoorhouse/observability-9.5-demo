output "instrumentation_ref" {
  description = "Instrumentation CR reference for instrumentation.opentelemetry.io/inject-<lang> annotations."
  value       = "${helm_release.kube_stack.namespace}/${local.instrumentation_name}"
}

output "namespace" {
  description = "Namespace of the OTel operator and EDOT collectors."
  value       = kubernetes_namespace_v1.otel.metadata[0].name
}
