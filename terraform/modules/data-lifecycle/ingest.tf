# -----------------------------------------------------------------------------
# error.culprit for OpenTelemetry errors
# -----------------------------------------------------------------------------
# Classic APM agents send structured stack frames and APM Server derives error.culprit from them.
# EDOT sends the stack trace as one string (exception.stacktrace), so nothing sets the culprit and
# the APM error pages show it empty. logs@custom is called by logs@default-pipeline, the default
# pipeline of logs-generic.otel-default, where OTel error events land. The script picks the first
# application frame (Python: the last one, innermost), falling back to the top frame, for the Java,
# Node.js, .NET and Python stack trace formats. attributes is a passthrough object, so
# attributes.error.culprit is queried as error.culprit.
resource "elasticstack_elasticsearch_ingest_pipeline" "logs_custom" {
  name        = "logs@custom"
  description = "Banking demo: derive error.culprit from exception.stacktrace on OTel error events"

  processors = [
    jsonencode({
      script = {
        tag            = "error-culprit"
        lang           = "painless"
        if             = "ctx.attributes instanceof Map && ctx.attributes.get('processor.event') == 'error' && ctx.attributes.get('exception.stacktrace') instanceof String && !ctx.attributes.containsKey('error.culprit')"
        source         = file("${path.module}/error_culprit.painless")
        ignore_failure = true
      }
    }),
  ]
}
