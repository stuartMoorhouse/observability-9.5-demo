#!/usr/bin/env bash
# Return the demo to its baseline state between runs.
#
#   scripts/reset-demo.sh [--rate N] [--keep-fx-rates] [--full [--no-wait] [--wait-timeout MIN]]
#
# Always:
# - turns every fault off (latency, errors, slow-db)
# - restores transfer-service APP_VERSION=1.4.2 BAD_RELEASE=false
# - uninstalls fx-rates (unless --keep-fx-rates) so scenario 1 can be re-run
# - restores the load generator to N req/s (default 5) with 1 replica
#
# With --full (rehearsal / pre-meeting reset), additionally:
# - resets the latency and availability SLOs (restores the full error budget)
# - redeploys every dashboard in dashboards/ from Git (discards UI edits)
# - waits until no observability alerts are active (default up to 15 min,
#   skip with --no-wait), so the next scenario run starts from a clean state
#
# Traces, logs, metrics, alert history and ML anomaly results are never deleted
# (resetting the ML job would also throw away its learned baseline).
set -euo pipefail

# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Must match modules/kibana-content/dashboards.tf and scripts/export-dashboard.sh.
DASHBOARDS_API="/api/dashboards"

RATE="${DEFAULT_LOAD_RATE}"
KEEP_FX=false
FULL=false
WAIT_ALERTS=true
WAIT_TIMEOUT_MIN=15

usage() {
  print_header "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}

while (($# > 0)); do
  case "$1" in
    --rate) RATE="${2:?--rate needs a value}"; shift 2 ;;
    --keep-fx-rates) KEEP_FX=true; shift ;;
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
  TOTAL=$([[ "${WAIT_ALERTS}" == "true" ]] && echo 6 || echo 5)
else
  TOTAL=3
fi

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
      warn "  ${count} alert(s) still active after ${WAIT_TIMEOUT_MIN} min. Check Observability > Alerts."
      return 1
    fi
    info "  ${count} alert(s) still active, waiting for recovery..."
    sleep 30
  done
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
  cat <<'EOF'

Reset complete. Notes:
  - Active alerts recover on their own once rules evaluate healthy data
    (threshold rules ~1-5 min; SLO burn-rate alerts after the short window
    clears, typically 5-15 min). Wait for recovery before re-running
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
  info "6/${TOTAL} Waiting for active alerts to recover (up to ${WAIT_TIMEOUT_MIN} min)"
  wait_for_alert_recovery || status=1
fi

echo
if ((status == 0)); then
  info "Full reset complete. Demo is at baseline: set the Kibana time picker to 'Last 15 minutes'."
else
  warn "Full reset finished with warnings (see above). Re-run or check Kibana before presenting."
fi
cat <<'EOF'
Not reset: alert history, ML anomaly results (the job keeps its baseline) and
historical telemetry. They do not affect the next run.
EOF
exit "${status}"
