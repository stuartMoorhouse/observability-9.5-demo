# Roles and demo users (spec scenario 3: per-role AI restriction).
#
# Kibana feature ids verified against Kibana 9.5 source / docs:
#   apm, infrastructure, logs, uptime, slo, observabilityCasesV3 (observability common/index.ts),
#   observabilityAIAssistant (observability_ai_assistant/common/feature.ts, "all" only),
#   agentBuilder (Agent Builder permissions doc: feature_agentBuilder.read|all),
#   actions (actions/server/feature.ts; Agent Builder needs feature_actions.read to use connectors),
#   discover_v2, dashboard_v2, visualize_v2 (features/server/oss_features.ts), ml, stackAlerts,
#   workflowsManagement (Workflows setup doc: All or Read for Analytics > Workflows).
#
# demo-sre:    Observability all + Observability AI Assistant + Agent Builder + Actions and Connectors + Workflows,
#              plus monitor_inference (required for the Elastic Managed LLM / Inference API).
# demo-viewer: Observability read only. No observabilityAIAssistant, agentBuilder or actions feature and no
#              monitor_inference, so AI Assistant / AI Agent are hidden or return 403.

locals {
  observability_data_indices = ["logs-*", "metrics-*", "traces-*"]
  observability_system_read  = [".slo-observability.*", ".alerts-observability.*", ".ml-anomalies-*"]
}

resource "elasticstack_kibana_security_role" "demo_sre" {
  name        = "demo-sre"
  description = "Banking demo SRE: Observability all, AI Assistant, Agent Builder, connectors."

  elasticsearch {
    cluster = ["monitor", "monitor_ml", "monitor_inference", "manage_transform", "manage_ingest_pipelines", "read_pipeline"]

    indices {
      names      = local.observability_data_indices
      privileges = ["read", "view_index_metadata"]
    }
    indices {
      names      = local.observability_system_read
      privileges = ["read", "view_index_metadata"]
    }
    # Required to create/edit SLOs (SLO feature "all") - SLO summary and rollup indices.
    indices {
      names      = [".slo-observability.*"]
      privileges = ["read", "view_index_metadata", "write", "manage"]
    }
  }

  kibana {
    spaces = [var.space_id]

    feature {
      name       = "apm"
      privileges = ["all"]
    }
    feature {
      name       = "infrastructure"
      privileges = ["all"]
    }
    feature {
      name       = "logs"
      privileges = ["all"]
    }
    feature {
      name       = "uptime"
      privileges = ["all"]
    }
    feature {
      name       = "slo"
      privileges = ["all"]
    }
    feature {
      name       = "observabilityCasesV3"
      privileges = ["all"]
    }
    feature {
      name       = "ml"
      privileges = ["all"]
    }
    feature {
      name       = "stackAlerts"
      privileges = ["all"]
    }
    feature {
      name       = "discover_v2"
      privileges = ["all"]
    }
    feature {
      name       = "dashboard_v2"
      privileges = ["all"]
    }
    feature {
      name       = "visualize_v2"
      privileges = ["all"]
    }
    feature {
      name       = "observabilityAIAssistant"
      privileges = ["all"]
    }
    feature {
      name       = "agentBuilder"
      privileges = ["all"]
    }
    feature {
      name       = "actions"
      privileges = ["all"]
    }
    feature {
      name       = "workflowsManagement"
      privileges = ["all"]
    }
  }
}

resource "elasticstack_kibana_security_role" "demo_viewer" {
  name        = "demo-viewer"
  description = "Banking demo viewer: Observability read only, no AI Assistant / Agent Builder / connectors."

  elasticsearch {
    cluster = ["monitor_ml"]

    indices {
      names      = local.observability_data_indices
      privileges = ["read", "view_index_metadata"]
    }
    indices {
      names      = local.observability_system_read
      privileges = ["read", "view_index_metadata"]
    }
  }

  kibana {
    spaces = [var.space_id]

    feature {
      name       = "apm"
      privileges = ["read"]
    }
    feature {
      name       = "infrastructure"
      privileges = ["read"]
    }
    feature {
      name       = "logs"
      privileges = ["read"]
    }
    feature {
      name       = "uptime"
      privileges = ["read"]
    }
    feature {
      name       = "slo"
      privileges = ["read"]
    }
    feature {
      name       = "observabilityCasesV3"
      privileges = ["read"]
    }
    feature {
      name       = "ml"
      privileges = ["read"]
    }
    feature {
      name       = "discover_v2"
      privileges = ["read"]
    }
    feature {
      name       = "dashboard_v2"
      privileges = ["read"]
    }
    feature {
      name       = "visualize_v2"
      privileges = ["read"]
    }
  }
}

resource "random_password" "demo_sre" {
  length           = 24
  special          = true
  override_special = "-_.!"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
}

resource "random_password" "demo_viewer" {
  length           = 24
  special          = true
  override_special = "-_.!"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
}

resource "elasticstack_elasticsearch_security_user" "demo_sre" {
  username  = "demo-sre"
  full_name = "Banking demo SRE"
  password  = random_password.demo_sre.result
  roles     = [elasticstack_kibana_security_role.demo_sre.name]
}

resource "elasticstack_elasticsearch_security_user" "demo_viewer" {
  username  = "demo-viewer"
  full_name = "Banking demo viewer"
  password  = random_password.demo_viewer.result
  roles     = [elasticstack_kibana_security_role.demo_viewer.name]
}

# demo-reset: used only by scripts/reset-demo.sh --full to delete the AI triage workflow's run history.
# The Workflows API has no delete endpoint for executions, and .workflows-executions /
# .workflows-step-executions are restricted indices that even the superuser cannot write to unless a role
# grants allow_restricted_indices. Scoped to those two indices; no Kibana access.
resource "elasticstack_elasticsearch_security_role" "demo_reset" {
  name = "demo-reset"

  indices {
    names                    = [".workflows-executions", ".workflows-step-executions"]
    privileges               = ["read", "delete"]
    allow_restricted_indices = true
  }
}

resource "random_password" "demo_reset" {
  length           = 24
  special          = true
  override_special = "-_.!"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
}

resource "elasticstack_elasticsearch_security_user" "demo_reset" {
  username  = "demo-reset"
  full_name = "Banking demo reset (workflow history cleanup)"
  password  = random_password.demo_reset.result
  roles     = [elasticstack_elasticsearch_security_role.demo_reset.name]
}
