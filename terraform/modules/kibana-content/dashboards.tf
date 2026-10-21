# Dashboards as code (spec scenario 5).
#
# File format (shared with scripts/export-dashboard.sh): var.dashboards_dir/<slug>.json =
#   { "id": "<dashboard id>", "data": { <Dashboards API dashboard body: title, panels, time_range, ...> } }
# "id" falls back to the file name without .json; a file without "data" is treated as the bare body.
#
# Deploy: Kibana Dashboards API (GA in 9.5)
#   PUT /api/dashboards/<id>   headers: kbn-xsrf: true, Content-Type: application/json   body: <data> (flat,
#   NOT wrapped in {"data": ...}; schema Kibana_HTTP_APIs_kbn-dashboard-data, additionalProperties false, so the
#   body must not contain id/meta/spaces).
# PUT creates the dashboard with that id if missing or fully replaces it, so ids are stable and re-applying
# overwrites UI edits. The Technical Preview elasticstack_kibana_dashboard resource is intentionally not used.
#
# A null_resource per file re-runs when the file hash changes. Credentials reach curl only through the
# environment and a curl config read from stdin (printf is a shell builtin), so they never appear in the command
# string, Terraform output or the process list. Because the environment contains a sensitive value, Terraform
# suppresses provisioner output; failures still fail the apply. No destroy-time provisioner.

locals {
  dashboard_files = fileset(var.dashboards_dir, "*.json")

  dashboard_docs = {
    for f in local.dashboard_files : f => jsondecode(file("${var.dashboards_dir}/${f}"))
  }

  dashboards = {
    for f, doc in local.dashboard_docs : try(doc.id, trimsuffix(f, ".json")) => {
      path = "${var.dashboards_dir}/${f}"
      body = jsonencode(try(doc.data, doc))
    }
  }

  kibana_space_prefix = var.space_id == "default" ? "" : "/s/${var.space_id}"
}

resource "null_resource" "dashboard" {
  for_each = local.dashboards

  triggers = {
    file_sha256  = filesha256(each.value.path)
    dashboard_id = each.key
    kibana_url   = var.kibana_endpoint
    space_id     = var.space_id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      resp="$(mktemp)"; body="$(mktemp)"
      trap 'rm -f "$resp" "$body"' EXIT
      printf '%s' "$DASHBOARD_BODY" > "$body"
      u="$${KIBANA_USER//\\/\\\\}"; u="$${u//\"/\\\"}"
      p="$${KIBANA_PASSWORD//\\/\\\\}"; p="$${p//\"/\\\"}"
      code="$(printf 'user = "%s:%s"\n' "$u" "$p" | curl -sS -K - \
        -o "$resp" -w '%%{http_code}' \
        -X PUT "$${KIBANA_URL%/}$${SPACE_PREFIX}/api/dashboards/$${DASHBOARD_ID}" \
        -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
        --data-binary @"$body")"
      if [[ "$code" != 2* ]]; then
        echo "Dashboards API PUT $${DASHBOARD_ID} failed with HTTP $code:" >&2
        cat "$resp" >&2
        exit 1
      fi
      echo "Dashboard $${DASHBOARD_ID} deployed (HTTP $code)"
    EOT

    environment = {
      KIBANA_URL      = var.kibana_endpoint
      KIBANA_USER     = var.elastic_username
      KIBANA_PASSWORD = var.elastic_password
      SPACE_PREFIX    = local.kibana_space_prefix
      DASHBOARD_ID    = each.key
      DASHBOARD_BODY  = each.value.body
    }
  }
}
