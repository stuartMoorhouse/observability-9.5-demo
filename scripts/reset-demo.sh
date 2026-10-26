#!/usr/bin/env bash
# Reset the demo and leave it ready for every scenario in docs/runbook.md.
#
#   scripts/reset-demo.sh [--rate N] [--keep-fx-rates] [--no-fault] [--full [--no-wait] [--wait-timeout MIN]]
#
# Always:
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
# - closes the open AI triage cases (tag ai-triage) created by the triage workflow,
#   so the next bad release opens a fresh one
# The bad release is turned on after these steps, so its SLO burn-rate alert is a
# new alert against a full error budget (scripts/detection-delay.sh measures it).
#
# Traces, logs, metrics, alert history and ML anomaly results are never deleted
# (resetting the ML job would also throw away its learned baseline).
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

usage() {
  print_header "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}

while (($# > 0)); do
  case "$1" in
    --rate) RATE="${2:?--rate needs a value}"; shift 2 ;;
    --keep-fx-rates) KEEP_FX=true; shift ;;
    --no-fault) NO_FAULT=true; shift ;;
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

# Close the open cases the AI triage workflow opened (terraform/modules/kibana-content/triage.tf).
close_triage_cases() {
  local found body count
  found="$(kb_api GET "/api/cases/_find?owner=observability&tags=ai-triage&status=open&status=in-progress&perPage=100")" ||
    return 1
  count="$(jq -r '.cases | length' <<<"${found}")"
  if [[ "${count}" == "0" ]]; then
    info "  No open AI triage cases"
    return 0
  fi
  body="$(jq -c '{cases: [.cases[] | {id, version, status: "closed"}]}' <<<"${found}")"
  kb_api PATCH "/api/cases" "${body}" >/dev/null || return 1
  info "  Closed ${count} AI triage case(s)"
}

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

info "7/${TOTAL} Closing AI triage cases"
close_triage_cases || { error "  Closing AI triage cases failed"; status=1; }

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
Not reset: alert history, ML anomaly results (the job keeps its baseline) and
historical telemetry. They do not affect the next run.
EOF
exit "${status}"
