#!/usr/bin/env bash
# Drive an SLO breach on transfer-service and measure burn-rate detection delay.
#
#   scripts/slo-breach.sh [--latency MS] [--timeout MIN] [--interval SEC] [--keep-fault]
#
#   --latency MS    injected latency on POST /transfer (default 3000, well above
#                   the SLO latency threshold so every transfer is a bad event)
#   --timeout MIN   give up after MIN minutes (default 30)
#   --interval SEC  poll interval (default 15)
#   --keep-fault    leave the latency fault on at the end (for the walkthrough)
#
# Detection = first SLO alert for burn_rate_rule_id (Terraform output) whose
# kibana.alert.start is at or after the fault start, read from the SLO alerts
# index .alerts-observability.slo.alerts-* via Elasticsearch _search.
# Result: results/slo-breach-<timestamp>.json
set -euo pipefail

# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LATENCY_MS=3000
TIMEOUT_MIN=30
INTERVAL_SEC=15
KEEP_FAULT=false
FAULT_ENABLED=false
ALERTS_INDEX=".alerts-observability.slo.alerts-*"

usage() {
  print_header "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}

while (($# > 0)); do
  case "$1" in
    --latency) LATENCY_MS="${2:?--latency needs a value}"; shift 2 ;;
    --timeout) TIMEOUT_MIN="${2:?--timeout needs a value}"; shift 2 ;;
    --interval) INTERVAL_SEC="${2:?--interval needs a value}"; shift 2 ;;
    --keep-fault) KEEP_FAULT=true; shift ;;
    -h | --help) usage 0 ;;
    *) error "Unknown argument: $1"; usage 1 ;;
  esac
done
is_int "${LATENCY_MS}" || die "--latency must be an integer"
is_int "${TIMEOUT_MIN}" || die "--timeout must be an integer"
if ! is_int "${INTERVAL_SEC}" || ((INTERVAL_SEC == 0)); then
  die "--interval must be a positive integer"
fi

cleanup() {
  local rc=$?
  if [[ "${FAULT_ENABLED}" == "true" ]]; then
    if [[ "${KEEP_FAULT}" == "true" ]]; then
      warn "Leaving latency fault ON (--keep-fault). Turn it off with: scripts/fault-inject.sh latency off"
    else
      info "Turning latency fault off."
      "${SCRIPTS_DIR}/fault-inject.sh" latency off >/dev/null || warn "Could not turn the fault off; run: scripts/fault-inject.sh latency off"
    fi
  fi
  exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

alerts_query() {
  # alerts_query RULE_ID SINCE_ISO [STATUS]
  local filters
  filters="$(jq -nc --arg r "$1" --arg s "$2" --arg st "${3:-}" '
    [{term: {"kibana.alert.rule.uuid": $r}}]
    + (if $s  != "" then [{range: {"kibana.alert.start": {gte: $s}}}] else [] end)
    + (if $st != "" then [{term: {"kibana.alert.status": $st}}] else [] end)')"
  jq -nc --argjson f "${filters}" '{
    size: 1,
    sort: [{"kibana.alert.start": "asc"}],
    query: {bool: {filter: $f}},
    _source: ["kibana.alert.start", "kibana.alert.uuid", "kibana.alert.instance.id",
              "kibana.alert.reason", "kibana.alert.status", "kibana.alert.rule.name",
              "kibana.alert.evaluation.value", "slo.id", "slo.instanceId"]
  }'
}

search_alerts() {
  es_api POST "/$(uri_encode "${ALERTS_INDEX}")/_search?ignore_unavailable=true&allow_no_indices=true&expand_wildcards=open,hidden" "$1"
}

main() {
  require_cmd jq curl kubectl terraform
  load_env
  ensure_kube
  check_elastic
  mkdir -p "${RESULTS_DIR}"

  local rule_id slo_id rule_json rule_name
  rule_id="$(tf_out burn_rate_rule_id)"
  slo_id="$(tf_out_opt slo_id)"

  if ! rule_json="$(kb_api GET "/api/alerting/rule/$(uri_encode "${rule_id}")")"; then
    die "Burn-rate rule ${rule_id} not found via Kibana alerting API: ${rule_json}"
  fi
  rule_name="$(jq -r '.name // "unknown"' <<<"${rule_json}")"
  [[ "$(jq -r '.enabled' <<<"${rule_json}")" == "true" ]] ||
    die "Burn-rate rule '${rule_name}' (${rule_id}) is disabled. Enable it in Stack Management > Rules."
  info "Burn-rate rule: ${rule_name} (${rule_id}), interval $(jq -r '.schedule.interval // "?"' <<<"${rule_json}")"

  local active
  active="$(search_alerts "$(alerts_query "${rule_id}" "" active)" | jq -r '.hits.total.value // 0')"
  if ((active > 0)); then
    warn "There are already ${active} active burn-rate alert(s) for this rule. A new alert is only created after they recover; the measured delay may be missing or misleading. Consider scripts/reset-demo.sh and waiting for recovery."
  fi

  local fault_start fault_start_epoch ts out_file
  ts="$(utc_stamp)"
  out_file="${RESULTS_DIR}/slo-breach-${ts}.json"
  fault_start="$(utc_now)"
  fault_start_epoch="$(iso_to_epoch "${fault_start}")"
  info "Fault start: ${fault_start}. Enabling latency fault ${LATENCY_MS} ms on transfer-service."
  FAULT_ENABLED=true
  "${SCRIPTS_DIR}/fault-inject.sh" latency on "${LATENCY_MS}" >/dev/null

  local deadline=$((fault_start_epoch + TIMEOUT_MIN * 60))
  local resp hit="" detected_at="" polls=0
  info "Polling ${ALERTS_INDEX} every ${INTERVAL_SEC}s for up to ${TIMEOUT_MIN} min..."
  while (($(epoch_now) < deadline)); do
    polls=$((polls + 1))
    if resp="$(search_alerts "$(alerts_query "${rule_id}" "${fault_start}")")"; then
      hit="$(jq -c '.hits.hits[0]._source // empty' <<<"${resp}")"
      if [[ -n "${hit}" ]]; then
        detected_at="$(utc_now)"
        break
      fi
    else
      warn "Alert search failed (will retry): ${resp}"
    fi
    if ((polls % 4 == 0)); then
      info "No burn-rate alert yet ($(($(epoch_now) - fault_start_epoch))s elapsed)."
    fi
    sleep "${INTERVAL_SEC}"
  done

  local detected=false alert_start="" delay="null" poll_delay="null"
  if [[ -n "${hit}" ]]; then
    detected=true
    alert_start="$(jq -r '.["kibana.alert.start"] // .kibana.alert.start // empty' <<<"${hit}")"
    [[ -n "${alert_start}" ]] || alert_start="${detected_at}"
    delay=$(($(iso_to_epoch "${alert_start}") - fault_start_epoch))
    poll_delay=$(($(iso_to_epoch "${detected_at}") - fault_start_epoch))
    info "Burn-rate alert detected. Alert start ${alert_start}; detection delay ${delay}s (seen by poller after ${poll_delay}s)."
  else
    warn "No burn-rate alert within ${TIMEOUT_MIN} min."
  fi

  jq -n \
    --arg fault_start "${fault_start}" \
    --argjson alert_detected "${detected}" \
    --arg alert_start "${alert_start}" \
    --arg detected_at "${detected_at}" \
    --argjson delay "${delay}" \
    --argjson poll_delay "${poll_delay}" \
    --argjson latency "${LATENCY_MS}" \
    --argjson timeout "${TIMEOUT_MIN}" \
    --arg rule_id "${rule_id}" \
    --arg rule_name "${rule_name}" \
    --arg slo_id "${slo_id}" \
    --argjson alert "${hit:-null}" \
    '{
      scenario: "slo-burn-rate",
      fault: {mode: "latency", service: "transfer-service", latency_ms: $latency},
      fault_start: $fault_start,
      alert_detected: $alert_detected,
      alert_start: (if $alert_start == "" then null else $alert_start end),
      detected_at: (if $detected_at == "" then null else $detected_at end),
      detection_delay_seconds: $delay,
      poll_detection_delay_seconds: $poll_delay,
      timeout_minutes: $timeout,
      burn_rate_rule_id: $rule_id,
      burn_rate_rule_name: $rule_name,
      slo_id: (if $slo_id == "" then null else $slo_id end),
      alert: $alert
    }' >"${out_file}"
  info "Result written to ${out_file}"
  set_env_flag demo_executed true

  printf '\nDrill-through:\n'
  printf '  SLO list:   %s/app/slos\n' "${KB_URL}"
  [[ -n "${slo_id}" ]] && printf '  SLO detail: %s/app/slos/%s?instanceId=transfer-service\n' "${KB_URL}" "${slo_id}"
  printf '  Alerts:     %s/app/observability/alerts\n' "${KB_URL}"

  [[ "${detected}" == "true" ]] || exit 2
}

main
