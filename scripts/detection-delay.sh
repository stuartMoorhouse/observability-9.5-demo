#!/usr/bin/env bash
# Measure how long the platform took to detect the bad release (runbook scenario 4).
#
#   scripts/detection-delay.sh [--timeout MIN] [--interval SEC]
#
#   --timeout MIN   give up after MIN minutes from the bad release start (default 15)
#   --interval SEC  poll interval (default 15)
#
# Start = the time the bad release was turned on, from the transfer-service
# Deployment annotation demo.elastic.co/bad-release-start (set by
# scripts/fault-inject.sh, scripts/reset-demo.sh and the demo-control-panel).
# Detection = the first time the availability SLO burn-rate rule (Terraform output
# availability_burn_rate_rule_id) reports instance transfer-service in a paging
# action group (fast burn "alert" or "high"), read from the Kibana event log.
# The low-severity ticket windows can fire earlier (right after an SLO reset the
# 24 h window holds only minutes of data); that time is recorded separately.
# Polls until the paging alert exists, so it can run right after a reset.
# Result: results/detection-delay-<timestamp>.json
set -euo pipefail

# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TIMEOUT_MIN=15
INTERVAL_SEC=15
INSTANCE="transfer-service"
EVENT_LOG_INDEX=".kibana-event-log-*"
PAGING_GROUPS='["slo.burnRate.alert", "slo.burnRate.high"]'

usage() {
  print_header "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}

while (($# > 0)); do
  case "$1" in
    --timeout) TIMEOUT_MIN="${2:?--timeout needs a value}"; shift 2 ;;
    --interval) INTERVAL_SEC="${2:?--interval needs a value}"; shift 2 ;;
    -h | --help) usage 0 ;;
    *) error "Unknown argument: $1"; usage 1 ;;
  esac
done
is_int "${TIMEOUT_MIN}" || die "--timeout must be an integer"
if ! is_int "${INTERVAL_SEC}" || ((INTERVAL_SEC == 0)); then
  die "--interval must be a positive integer"
fi

events_query() {
  # events_query RULE_ID SINCE_ISO GROUPS_JSON -> first active-instance event for the instance
  jq -nc --arg r "$1" --arg s "$2" --argjson g "$3" --arg i "${INSTANCE}" '{
    size: 1,
    sort: [{"@timestamp": "asc"}],
    query: {bool: {filter: [
      {range: {"@timestamp": {gte: $s}}},
      {term: {"event.provider": "alerting"}},
      {term: {"event.action": "active-instance"}},
      {term: {"kibana.alerting.instance_id": $i}},
      {terms: {"kibana.alerting.action_group_id": $g}},
      {nested: {path: "kibana.saved_objects", query: {term: {"kibana.saved_objects.id": $r}}}}
    ]}},
    _source: ["@timestamp", "kibana.alerting.action_group_id", "message"]
  }'
}

search_events() {
  es_api POST "/$(uri_encode "${EVENT_LOG_INDEX}")/_search?ignore_unavailable=true&allow_no_indices=true&expand_wildcards=open,hidden" "$1"
}

main() {
  require_cmd jq curl kubectl terraform
  load_env
  ensure_kube
  check_elastic
  mkdir -p "${RESULTS_DIR}"

  local bad start
  bad="$(kctl get deployment transfer-service -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="BAD_RELEASE")].value}')"
  [[ "${bad}" == "true" ]] ||
    die "The bad release is not on. Run scripts/reset-demo.sh --full (or scripts/fault-inject.sh bad-version on) first."
  start="$(kctl get deployment transfer-service -o jsonpath="{.metadata.annotations.${BAD_RELEASE_START_ANNOTATION//./\\.}}")"
  [[ -n "${start}" ]] ||
    die "transfer-service has no ${BAD_RELEASE_START_ANNOTATION} annotation, so the start time is unknown. Turn the bad release off and on again (scripts/fault-inject.sh bad-version off && scripts/fault-inject.sh bad-version on)."

  local rule_id rule_name
  rule_id="$(tf_out availability_burn_rate_rule_id)"
  rule_name="$(kb_api GET "/api/alerting/rule/$(uri_encode "${rule_id}")" | jq -r '.name // "unknown"')" ||
    die "Burn-rate rule ${rule_id} not found via Kibana alerting API."
  info "Bad release started: ${start}"
  info "Waiting for '${rule_name}' to page for ${INSTANCE} (up to ${TIMEOUT_MIN} min after the start)..."

  local start_epoch deadline resp hit=""
  start_epoch="$(iso_to_epoch "${start}")"
  deadline=$((start_epoch + TIMEOUT_MIN * 60))
  while :; do
    if resp="$(search_events "$(events_query "${rule_id}" "${start}" "${PAGING_GROUPS}")")"; then
      hit="$(jq -c '.hits.hits[0]._source // empty' <<<"${resp}")"
      [[ -n "${hit}" ]] && break
    else
      warn "Event log search failed (will retry): ${resp}"
    fi
    (($(epoch_now) < deadline)) || break
    info "No paging burn-rate alert yet ($(($(epoch_now) - start_epoch))s since the bad release started)."
    sleep "${INTERVAL_SEC}"
  done

  local ts out_file paged_at="" group="" delay="" first="" first_at="" first_group="" first_delay=""
  ts="$(utc_stamp)"
  out_file="${RESULTS_DIR}/detection-delay-${ts}.json"
  if [[ -n "${hit}" ]]; then
    paged_at="$(jq -r '.["@timestamp"]' <<<"${hit}")"
    group="$(jq -r '.kibana.alerting.action_group_id' <<<"${hit}")"
    delay=$(($(iso_to_epoch "${paged_at}") - start_epoch))
  fi
  # First alert in any group, for reference (often a low-severity ticket window).
  first="$(search_events "$(events_query "${rule_id}" "${start}" '["slo.burnRate.alert", "slo.burnRate.high", "slo.burnRate.medium", "slo.burnRate.low"]')" |
    jq -c '.hits.hits[0]._source // empty' 2>/dev/null || true)"
  if [[ -n "${first}" ]]; then
    first_at="$(jq -r '.["@timestamp"]' <<<"${first}")"
    first_group="$(jq -r '.kibana.alerting.action_group_id' <<<"${first}")"
    first_delay=$(($(iso_to_epoch "${first_at}") - start_epoch))
  fi
  jq -n --arg start "${start}" --arg rule_id "${rule_id}" --arg rule_name "${rule_name}" \
    --arg instance "${INSTANCE}" --arg paged_at "${paged_at}" --arg group "${group}" --arg delay "${delay}" \
    --arg first_at "${first_at}" --arg first_group "${first_group}" \
    --arg first_delay "${first_delay}" '
    def num: if . == "" then null else tonumber end;
    def str: if . == "" then null else . end;
    {
      fault: "bad-version",
      fault_start: $start,
      burn_rate_rule_id: $rule_id,
      burn_rate_rule_name: $rule_name,
      slo_instance: $instance,
      alert_detected: ($paged_at != ""),
      paging_alert_at: ($paged_at | str),
      paging_action_group: ($group | str),
      detection_delay_seconds: ($delay | num),
      first_alert_at: ($first_at | str),
      first_alert_action_group: ($first_group | str),
      first_alert_delay_seconds: ($first_delay | num)
    }' >"${out_file}"

  if [[ -z "${hit}" ]]; then
    warn "No paging burn-rate alert for ${INSTANCE} within ${TIMEOUT_MIN} min of the bad release start."
    warn "If an alert from an earlier run was still active, no new one is raised: use scripts/reset-demo.sh --full."
    printf 'Results: %s\n' "${out_file}"
    exit 1
  fi
  printf '\nDetection delay\n'
  printf '  Bad release started: %s\n' "${start}"
  printf '  Paging alert:        %s (%s)\n' "${paged_at}" "${group}"
  printf '  Detection delay:     %ss\n' "${delay}"
  if [[ -n "${first_at}" && "${first_at}" != "${paged_at}" ]]; then
    printf '  First alert:         %s (%s, +%ss)\n' "${first_at}" "${first_group}" "${first_delay}"
  fi
  printf '\nResults: %s\n' "${out_file}"
}

main
