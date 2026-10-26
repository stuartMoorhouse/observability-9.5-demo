# AI triage (runbook scenario 3a): an Agent Builder agent plus an Elastic Workflow that runs it when the
# error-rate rule raises a new alert (rules.tf, system action system-connector-.workflows).
#
# The workflow (workflows/alert-triage.yaml) runs the agent with structured output, opens an Observability
# case with the findings and attaches the alert. The agent's conversation is kept (create-conversation), and
# the case links to it, so the tool calls behind the conclusion can be checked and the chat continued.
#
# Workflows is GA from 9.4: no advanced setting is needed, only the workflowsManagement feature privilege
# (security.tf). The agent uses the deployment's default LLM connector (Elastic Managed LLM).

locals {
  triage_agent_id = "banking-triage"
}

resource "elasticstack_kibana_agentbuilder_agent" "triage" {
  space_id    = var.space_id
  agent_id    = local.triage_agent_id
  name        = "Banking triage"
  description = "Investigates banking-demo alerts: finds the root cause from alerts, service topology, APM correlations, traces and logs, and cites the evidence for each finding."
  labels      = ["banking-demo", "observability"]

  tools = [
    "observability.get_alerts",
    "observability.get_services",
    "observability.get_service_topology",
    "observability.get_trace_metrics",
    "observability.get_trace_change_points",
    "observability.get_apm_correlations",
    "observability.get_traces",
    "observability.get_logs",
    "observability.get_log_groups",
    "observability.get_index_info",
    "platform.core.generate_esql",
    "platform.core.execute_esql",
    "platform.core.get_index_mapping",
  ]

  instructions = <<-EOT
    You are an SRE investigating alerts for a banking application in the ${var.environment} environment.
    Services: web-banking (Node.js, front door), transfer-service (Java), fraud-check (.NET),
    accounts-ledger (Python, PostgreSQL) and, when installed, fx-rates (Python). Traces and logs are
    OpenTelemetry data in traces-*.otel-* and logs-*.otel-*.

    Investigate in this order, as an experienced on-call engineer would:
    1. Alerts: which services are alerting, since when, and which alert started first.
    2. Topology: the alerting service's dependencies, and whether the problem starts there or upstream.
    3. Change: compare before and after the alert started. Use APM correlations and change points to
       find the attributes (service.version, pod, host, endpoint) that separate failed or slow
       transactions from healthy ones.
    4. Traces: read failed or slow traces and name the span and the error or exception.
    5. Logs: find the matching error logs for the same service and time.

    Rules:
    - Every finding must name the tool or query that produced it. Do not state anything the data does
      not show; say what is unknown instead.
    - Distinguish the service that fails from services that fail because they call it.
    - Prefer a recent deployment or version change as the cause only when the data ties the failures
      to it.
    - Keep the answer short and specific. Times in UTC.
  EOT
}

resource "elasticstack_kibana_agentbuilder_workflow" "triage" {
  space_id = var.space_id
  configuration_yaml = templatefile("${path.module}/workflows/alert-triage.yaml", {
    agent_id    = elasticstack_kibana_agentbuilder_agent.triage.agent_id
    environment = var.environment
    kibana_url  = trimsuffix(var.kibana_endpoint, "/")
  })
}
