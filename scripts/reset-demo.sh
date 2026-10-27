#!/usr/bin/env bash
# Reset the demo and leave it ready for every scenario in docs/runbook.md.
#
#   scripts/reset-demo.sh [--rate N] [--keep-fx-rates] [--no-fault] [--skip-ip-check] [--full [--no-wait] [--wait-timeout MIN]]
#
# Always:
# - checks this machine's public IP is in the EKS API and control panel / bank UI
#   allowlists, and re-applies them with Terraform if not (e.g. after changing network).
#   --skip-ip-check skips this.
# - turns every fault off (latency, errors, slow-db)
# - restores transfer-service APP_VERSION=1.4.2 BAD_RELEASE=false
# - uninstalls fx-rates (unless --keep-fx-rates) so scenario 1 can be re-run
# - restores the load generator to N req/s (default 5) with 1 replica
# - finally turns the bad release on (transfer-service 2.0.0): the incident that
#   scenarios 2-4 investigate. --no-fault leaves every fault off instead (clean
#   baseline, used by scripts/test-runbook.sh).
#
# With --full (rehearsal / pre-meeting reset), additionally:
# - resets the latency and availability SLOs (restores the full error budget)
# - redeploys every dashboard in dashboards/ from Git (discards UI edits)
# - waits until no observability alerts are active (default up to 6 min; with
#   the demo rule windows they recover ~5-6 min after the last fault), then
#   untracks any alert still active, so the next run starts from a clean
#   Alerts page. --no-wait untracks at once; an alert whose rule window still
#   holds fault data may then fire again within ~1 min and recover shortly after.
# - deletes the history of earlier runs, so the next run starts from a clean slate:
#   the demo rules' alerts, every Observability case (including the AI triage cases),
#   the AI triage workflow's runs and demo-sre's conversations with the triage agent
# The bad release is turned on after these steps, so its SLO burn-rate alert is a
# new alert against a full error budget (scripts/detection-delay.sh measures it).
#
# Traces, logs, metrics and ML anomaly results are never deleted (resetting the ML
# job would also throw away its learned baseline).
set -euo pipefail

# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Must match terraform/modules/kibana-content/dashboards.tf and scripts/export-dashboard.sh.
DASHBOARDS_API="/api/dashboards"

RATE="${DEFAULT_LOAD_RATE}"
KEEP_FX=false
NO_FAULT=false
FULL=false
WAIT_ALERTS=true
WAIT_TIMEOUT_MIN=6
IP_CHECK=true

usage() {
  print_header "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}

while (($# > 0)); do
  case "$1" in
    --rate) RATE="${2:?--rate needs a value}"; shift 2 ;;
    --keep-fx-rates) KEEP_FX=true; shift ;;
    --no-fault) NO_FAULT=true; shift ;;
    --skip-ip-check) IP_CHECK=false; shift ;;
    --full) FULL=true; shift ;;
    --no-wait) WAIT_ALERTS=false; shift ;;
    --wait-timeout) WAIT_TIMEOUT_MIN="${2:?--wait-timeout needs a value}"; shift 2 ;;
    -h | --help) usage 0 ;;
    *) error "Unknown argument: $1"; usage 1 ;;
  esac
done
is_int "${RATE}" || die "--rate must be an integer"
is_int "${WAIT_TIMEOUT_MIN}" || die "--wait-timeout must be an integer (minutes)"

if [[ "${FULL}" == "true" ]]; then
  TOTAL=8
else
  TOTAL=4
fi

# Last step of every reset: start the scenario 2-4 incident, or leave all faults off.
start_bad_release() {
  if [[ "${NO_FAULT}" == "true" ]]; then
    info "${TOTAL}/${TOTAL} Leaving every fault off (--no-fault)"
  else
    info "${TOTAL}/${TOTAL} Turning on the bad release (transfer-service ${BAD_VERSION}) for scenarios 2-4"
    "${SCRIPTS_DIR}/fault-inject.sh" bad-version on
  fi
}

reset_slos() {
  local id ids=() failed=0
  ids+=("$(tf_out slo_id)")
  id="$(tf_out_opt availability_slo_id)"
  [[ -n "${id}" ]] && ids+=("${id}")
  for id in "${ids[@]}"; do
    if kb_api POST "/api/observability/slos/$(uri_encode "${id}")/_reset" >/dev/null; then
      info "  SLO ${id} reset"
    else
      error "  SLO ${id} reset failed"
      failed=1
    fi
  done
  return "${failed}"
}

redeploy_dashboards() {
  local f id body failed=0 count=0
  shopt -s nullglob
  for f in "${REPO_ROOT}"/dashboards/*.json; do
    id="$(jq -r --arg d "$(basename "${f}" .json)" '.id // $d' "${f}")"
    body="$(jq -c 'if has("data") then .data else . end' "${f}")"
    if kb_api PUT "${DASHBOARDS_API}/$(uri_encode "${id}")" "${body}" >/dev/null; then
      info "  Dashboard ${id} restored from $(basename "${f}")"
      count=$((count + 1))
    else
      error "  Dashboard ${id} redeploy failed ($(basename "${f}"))"
      failed=1
    fi
  done
  shopt -u nullglob
  ((count > 0 || failed > 0)) || warn "  No dashboards found in dashboards/"
  return "${failed}"
}

active_alert_count() {
  local query
  query='{"query":{"bool":{"filter":[{"term":{"kibana.alert.status":"active"}}]}}}'
  es_api POST "/.alerts-observability.*/_count?expand_wildcards=open,hidden&ignore_unavailable=true&allow_no_indices=true" \
    "${query}" | jq -r '.count // 0'
}

wait_for_alert_recovery() {
  local deadline count
  deadline=$(($(epoch_now) + WAIT_TIMEOUT_MIN * 60))
  while :; do
    count="$(active_alert_count)" || die "Could not query active alerts."
    if [[ "${count}" == "0" ]]; then
      info "  No active observability alerts"
      return 0
    fi
    if (($(epoch_now) >= deadline)); then
      info "  ${count} alert(s) still active after ${WAIT_TIMEOUT_MIN} min, untracking them"
      return 1
    fi
    info "  ${count} alert(s) still active, waiting for recovery..."
    sleep 30
  done
}

# --- History clean-up (--full): a clean slate for the next run -------------------------------
# Same approach as the other demo repos: there is no supported API to delete alert history or
# workflow executions, so those are removed with _delete_by_query. Cases and conversations use
# their Kibana APIs.

# Alert documents of the demo rules (tag banking-demo). Runs after untrack_demo_alerts, which
# disables and re-enables every rule, so no rule state still refers to a deleted alert.
delete_demo_alerts() {
  local query resp
  query='{"query":{"term":{"kibana.alert.rule.tags":"banking-demo"}}}'
  resp="$(es_api POST "/.alerts-observability.*/_delete_by_query?expand_wildcards=open,hidden&refresh=true&conflicts=proceed" \
    "${query}")" || return 1
  info "  Deleted $(jq -r '.deleted // 0' <<<"${resp}") alert(s)"
}

# Every Observability case (the AI triage cases and any opened during a run), 100 per request.
delete_cases() {
  local found ids count total=0 pages=0
  while ((pages < 20)); do
    pages=$((pages + 1))
    found="$(kb_api GET "/api/cases/_find?owner=observability&perPage=100")" || return 1
    count="$(jq -r '.cases | length' <<<"${found}")"
    ((count > 0)) || break
    ids="$(jq -c '[.cases[].id]' <<<"${found}")"
    kb_api DELETE "/api/cases?ids=$(uri_encode "${ids}")" >/dev/null || return 1
    total=$((total + count))
  done
  info "  Deleted ${total} case(s)"
}

# Finished runs of the triage workflow and their step records. .workflows-executions and
# .workflows-step-executions are restricted indices: only the demo-reset user (security.tf) can
# delete from them. In-flight runs are left alone.
delete_workflow_runs() {
  local workflow_id password ids count index
  workflow_id="$(tf_out_opt triage_workflow_id)"
  password="$(tf_out_opt demo_reset_password)"
  if [[ -z "${workflow_id}" || -z "${password}" ]]; then
    warn "  Terraform outputs triage_workflow_id / demo_reset_password missing; skipping (run terraform apply)"
    return 0
  fi
  ids="$(_curl_auth demo-reset "${password}" -X POST -H "Content-Type: application/json" --fail-with-body \
    "${ES_URL}/.workflows-executions/_search" \
    --data-binary "$(jq -nc --arg w "${workflow_id}" '{size: 1000, _source: ["id"], query: {bool: {
      filter: [{term: {workflowId: $w}}],
      must_not: [{terms: {status: ["running", "pending", "waiting"]}}]}}}')" |
    jq -c '[.hits.hits[]._source.id]')" || return 1
  count="$(jq -r 'length' <<<"${ids}")"
  if ((count == 0)); then
    info "  No workflow runs to delete"
    return 0
  fi
  # No ?refresh=true: refreshing needs the maintenance privilege, which demo-reset does not have.
  # The indices refresh on their own within about a second.
  for index in .workflows-step-executions .workflows-executions; do
    _curl_auth demo-reset "${password}" -X POST -H "Content-Type: application/json" --fail-with-body \
      "${ES_URL}/${index}/_delete_by_query?conflicts=proceed" \
      --data-binary "$(jq -nc --argjson ids "${ids}" --arg i "${index}" \
        'if $i == ".workflows-executions" then {query: {terms: {id: $ids}}}
         else {query: {terms: {workflowRunId: $ids}}} end')" >/dev/null || return 1
  done
  info "  Deleted ${count} workflow run(s)"
}

# demo-sre's conversations with the triage agent (one per workflow run, plus follow-ups).
delete_triage_conversations() {
  local password ids id count=0
  password="$(tf_out_opt demo_sre_password)"
  [[ -n "${password}" ]] || return 0
  ids="$(_curl_auth demo-sre "${password}" -H "x-elastic-internal-origin: Kibana" --fail-with-body \
    "${KB_URL}/api/agent_builder/conversations" |
    jq -r '.results[] | select(.agent_id == "banking-triage") | .id')" || return 1
  for id in ${ids}; do
    _curl_auth demo-sre "${password}" -X DELETE -H "kbn-xsrf: true" -H "x-elastic-internal-origin: Kibana" \
      --fail-with-body "${KB_URL}/api/agent_builder/conversations/$(uri_encode "${id}")" >/dev/null || return 1
    count=$((count + 1))
  done
  info "  Deleted ${count} triage conversation(s)"
}

clear_history() {
  local failed=0
  untrack_demo_alerts >/dev/null || failed=1
  delete_demo_alerts || { error "  Deleting alerts failed"; failed=1; }
  delete_cases || { error "  Deleting cases failed"; failed=1; }
  delete_workflow_runs || { error "  Deleting workflow runs failed"; failed=1; }
  delete_triage_conversations || { error "  Deleting triage conversations failed"; failed=1; }
  return "${failed}"
}

[[ "${IP_CHECK}" == "true" ]] && ensure_ip_allowlisted
ensure_kube
if [[ "${FULL}" == "true" ]]; then
  require_cmd jq curl
  load_env
  check_elastic
fi

info "1/${TOTAL} Faults off and baseline release restored"
"${SCRIPTS_DIR}/fault-inject.sh" all off

if [[ "${KEEP_FX}" == "true" ]]; then
  info "2/${TOTAL} Keeping fx-rates (--keep-fx-rates)"
else
  info "2/${TOTAL} Removing fx-rates"
  "${SCRIPTS_DIR}/onboard-service.sh" uninstall
fi

info "3/${TOTAL} Load generator back to ${RATE} req/s"
"${SCRIPTS_DIR}/generate-load.sh" "${RATE}"

if [[ "${FULL}" != "true" ]]; then
  start_bad_release
  cat <<'EOF'

Reset complete. Notes:
  - Unless --no-fault was given, the bad release is now rolling out: scenario 2
    is ready in ~3-5 min, the SLO burn-rate alert for scenario 4 in ~5-6 min.
  - Alerts from the previous run are not cleared, so the bad release may not
    raise a new burn-rate alert. Use --full before a run that measures it.
  - Active alerts recover on their own once rules evaluate healthy data
    (threshold rules ~1-2 min; SLO burn-rate alerts ~5-6 min). Use --full to
    clear them at once. Wait for recovery before re-running
    scripts/slo-breach.sh, otherwise no new alert is created.
  - The SLO error budget consumed by a breach is only restored as the SLO
    time window rolls forward. Use --full to reset the SLOs and dashboards.
  - Historical traces/logs from the fault period stay in Elasticsearch; set
    the Kibana time picker to "Last 15 minutes" to show the healthy baseline.
EOF
  exit 0
fi

status=0

info "4/${TOTAL} Resetting SLOs"
reset_slos || status=1

info "5/${TOTAL} Redeploying dashboards from Git"
redeploy_dashboards || status=1

if [[ "${WAIT_ALERTS}" == "true" ]]; then
  info "6/${TOTAL} Waiting for active alerts to recover (up to ${WAIT_TIMEOUT_MIN} min), then untracking the rest"
  wait_for_alert_recovery || untrack_demo_alerts || status=1
else
  info "6/${TOTAL} Untracking active alerts (--no-wait)"
  untrack_demo_alerts || status=1
fi

info "7/${TOTAL} Deleting alert history, cases, AI triage workflow runs and conversations"
clear_history || status=1

start_bad_release || status=1

echo
if ((status == 0)); then
  if [[ "${NO_FAULT}" == "true" ]]; then
    info "Full reset complete. Demo is at baseline: set the Kibana time picker to 'Last 15 minutes'."
  else
    info "Full reset complete. The bad release is rolling out: scenario 2 is ready in ~3-5 min, the scenario 4 burn-rate alert in ~5-6 min."
  fi
else
  warn "Full reset finished with warnings (see above). Re-run or check Kibana before presenting."
fi
cat <<'EOF'
Not reset: ML anomaly results (the job keeps its baseline) and historical
telemetry. Set the Kibana time picker to 'Last 15 minutes'.
EOF
exit "${status}"
