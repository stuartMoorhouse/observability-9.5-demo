#!/usr/bin/env bash
# Toggle demo faults in the banking app.
#
#   scripts/fault-inject.sh <latency|errors|slow-db|bad-version|all> <on|off> [value]
#   scripts/fault-inject.sh status
#
# latency      transfer-service adds VALUE ms to POST /transfer   (default 1500)
# errors       fraud-check returns HTTP 500 for VALUE % of calls  (default 30)
# slow-db      accounts-ledger runs a slow query (pg_sleep)
# bad-version  transfer-service rolls out service.version 2.0.0 with a regression
# all          every mode above
#
# ConfigMap faults are read by the services at most every 5 s (no restart).
# The kubelet only refreshes mounted ConfigMaps on its sync loop (60-90 s), so
# after patching, the target pods are annotated to force an immediate resync
# (typically 5-20 s end to end).
# bad-version changes the Deployment env and triggers a rollout.
# Note: the ConfigMap and Deployment are Helm-managed; a later
# 'terraform apply' resets them to defaults.
set -euo pipefail

# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DEFAULT_LATENCY_MS=1500
DEFAULT_ERROR_RATE=30

usage() {
  print_header "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}

# Service that reads each fault key.
fault_target() {
  case "$1" in
    LATENCY_MS) echo transfer-service ;;
    ERROR_RATE) echo fraud-check ;;
    SLOW_DB) echo accounts-ledger ;;
  esac
}

# Updating a pod's annotations makes the kubelet resync it, which refreshes
# mounted ConfigMap volumes now instead of on the next 60-90 s sync.
nudge_pods() {
  local svc="$1"
  if kctl annotate pods -l "app.kubernetes.io/name=${svc}" \
    "banking-demo/fault-config-updated=$(epoch_now)" --overwrite >/dev/null; then
    return 0
  fi
  warn "Could not annotate ${svc} pods; the change may take 60-90 s to reach them."
  return 1
}

patch_fault() {
  local key="$1" val="$2" current svc
  current="$(fault_get "${key}")"
  if [[ "${current}" == "${val}" ]]; then
    info "${FAULT_CONFIGMAP}.${key} already ${val}; no change."
    return 0
  fi
  kctl patch configmap "${FAULT_CONFIGMAP}" --type merge \
    -p "$(jq -nc --arg k "${key}" --arg v "${val}" '{data: {($k): $v}}')" >/dev/null
  svc="$(fault_target "${key}")"
  if nudge_pods "${svc}"; then
    info "${FAULT_CONFIGMAP}.${key}: '${current:-<unset>}' -> '${val}' (${svc} picks this up in ~5-20 s)"
  else
    info "${FAULT_CONFIGMAP}.${key}: '${current:-<unset>}' -> '${val}' (${svc} picks this up in ~60-90 s)"
  fi
}

set_release() {
  local version="$1" bad="$2" cur_version cur_bad
  cur_version="$(deploy_env transfer-service APP_VERSION)"
  cur_bad="$(deploy_env transfer-service BAD_RELEASE)"
  if [[ "${cur_version}" == "${version}" && "${cur_bad}" == "${bad}" ]]; then
    info "transfer-service already APP_VERSION=${version} BAD_RELEASE=${bad}; no change."
    return 0
  fi
  kctl set env deployment/transfer-service "APP_VERSION=${version}" "BAD_RELEASE=${bad}" >/dev/null
  info "transfer-service: APP_VERSION ${cur_version:-<unset>} -> ${version}, BAD_RELEASE ${cur_bad:-<unset>} -> ${bad}"
  info "Waiting for rollout (up to 5 min)..."
  if ! kctl rollout status deployment/transfer-service --timeout=300s >&2; then
    die "transfer-service rollout did not complete. Inspect: kubectl -n ${NAMESPACE} describe deployment transfer-service"
  fi
}

expect() {
  case "$1" in
    latency) info "Expect (from now, incl. ConfigMap propagation): latency threshold alert on transfer-service in ~1-2 min (rule runs every minute); SLO burn-rate alert in ~4 min if left on." ;;
    errors) info "Expect (from now, incl. ConfigMap propagation): fraud-check failed transaction rate rises within ~1 min; error-rate alert in ~1-2 min; APM correlations meaningful after ~3-5 min." ;;
    slow-db) info "Expect (from now, incl. ConfigMap propagation): slow DB span on accounts-ledger in trace waterfalls within ~1 min; latency alerts on accounts-ledger/transfer-service in ~5 min." ;;
    bad-version) info "Expect: service.version ${BAD_VERSION} visible in APM after rollout (~1-2 min); latency/error alerts in ~3-5 min; correlations rank version ${BAD_VERSION} after ~5 min." ;;
  esac
}

apply_mode() {
  local mode="$1" action="$2" value="${3:-}"
  case "${mode}:${action}" in
    latency:on)
      value="${value:-${DEFAULT_LATENCY_MS}}"
      is_int "${value}" || die "latency value must be an integer (ms), got '${value}'"
      patch_fault LATENCY_MS "${value}"
      ;;
    latency:off) patch_fault LATENCY_MS 0 ;;
    errors:on)
      value="${value:-${DEFAULT_ERROR_RATE}}"
      if ! is_int "${value}" || ((10#${value} > 100)); then
        die "errors value must be an integer 0-100 (%), got '${value}'"
      fi
      patch_fault ERROR_RATE "${value}"
      ;;
    errors:off) patch_fault ERROR_RATE 0 ;;
    slow-db:on) patch_fault SLOW_DB true ;;
    slow-db:off) patch_fault SLOW_DB false ;;
    bad-version:on) set_release "${BAD_VERSION}" true ;;
    bad-version:off) set_release "${BASE_VERSION}" false ;;
    *) usage 1 ;;
  esac
  [[ "${action}" == "on" ]] && expect "${mode}"
  return 0
}

show_status() {
  local data
  data="$(kctl get configmap "${FAULT_CONFIGMAP}" -o json | jq -c '.data // {}')"
  printf 'Fault state (namespace %s)\n' "${NAMESPACE}"
  printf '  latency      LATENCY_MS=%s\n' "$(jq -r '.LATENCY_MS // "0"' <<<"${data}")"
  printf '  errors       ERROR_RATE=%s\n' "$(jq -r '.ERROR_RATE // "0"' <<<"${data}")"
  printf '  slow-db      SLOW_DB=%s\n' "$(jq -r '.SLOW_DB // "false"' <<<"${data}")"
  printf '  bad-version  APP_VERSION=%s BAD_RELEASE=%s\n' \
    "$(deploy_env transfer-service APP_VERSION)" "$(deploy_env transfer-service BAD_RELEASE)"
}

main() {
  local mode="${1:-}" action="${2:-}" value="${3:-}"
  case "${mode}" in
    -h | --help | "") usage 0 ;;
  esac

  ensure_kube
  kctl get configmap "${FAULT_CONFIGMAP}" >/dev/null 2>&1 ||
    die "ConfigMap ${FAULT_CONFIGMAP} not found in namespace ${NAMESPACE}. Has the demo-app Helm release been deployed (terraform apply)?"

  if [[ "${mode}" == "status" ]]; then
    show_status
    return 0
  fi
  [[ "${action}" == "on" || "${action}" == "off" ]] || usage 1

  if [[ "${mode}" == "all" ]]; then
    [[ -z "${value}" ]] || warn "Value '${value}' ignored for mode 'all' (defaults used)."
    local m
    for m in latency errors slow-db bad-version; do
      apply_mode "${m}" "${action}"
    done
  else
    apply_mode "${mode}" "${action}" "${value}"
  fi
  show_status
}

main "$@"
