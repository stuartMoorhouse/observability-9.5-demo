#!/usr/bin/env bash
# Control the in-cluster k6 load generator (Deployment loadgen in banking).
#
#   scripts/generate-load.sh <rate>     set RATE (requests/s) and ensure it is running
#   scripts/generate-load.sh start      scale loadgen to 1 replica
#   scripts/generate-load.sh stop       scale loadgen to 0 replicas
#   scripts/generate-load.sh status     show replicas and RATE
#
# Note: loadgen is Helm-managed (Helm value loadgen.rate); 'terraform apply'
# resets RATE to the loadgen_rate variable.
set -euo pipefail

# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DEPLOY="loadgen"

usage() {
  print_header "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}

replicas() {
  kctl get deployment "${DEPLOY}" -o jsonpath='{.spec.replicas}'
}

scale_to() {
  local n="$1" cur
  cur="$(replicas)"
  if [[ "${cur}" == "${n}" ]]; then
    info "${DEPLOY} already at ${n} replica(s)."
    return 0
  fi
  kctl scale deployment "${DEPLOY}" --replicas="${n}" >/dev/null
  info "${DEPLOY}: replicas ${cur} -> ${n}"
  if ((n > 0)); then
    kctl rollout status deployment/"${DEPLOY}" --timeout=180s >&2 ||
      die "${DEPLOY} did not become ready. Inspect: kubectl -n ${NAMESPACE} describe deployment ${DEPLOY}"
  fi
}

set_rate() {
  local rate="$1" cur
  cur="$(deploy_env "${DEPLOY}" RATE)"
  if [[ "${cur}" == "${rate}" ]]; then
    info "${DEPLOY} RATE already ${rate} req/s."
  else
    kctl set env deployment/"${DEPLOY}" "RATE=${rate}" >/dev/null
    info "${DEPLOY}: RATE ${cur:-<unset>} -> ${rate} req/s (pod restarts to apply)"
  fi
  scale_to 1
}

status() {
  printf 'loadgen (namespace %s): replicas=%s ready=%s RATE=%s req/s\n' "${NAMESPACE}" \
    "$(replicas)" \
    "$(kctl get deployment "${DEPLOY}" -o jsonpath='{.status.readyReplicas}')" \
    "$(deploy_env "${DEPLOY}" RATE)"
}

main() {
  local arg="${1:-}"
  case "${arg}" in
    "" | -h | --help) usage 0 ;;
  esac
  ensure_kube
  kctl get deployment "${DEPLOY}" >/dev/null 2>&1 ||
    die "Deployment ${DEPLOY} not found in ${NAMESPACE}. Has the demo-app Helm release been deployed (terraform apply)?"
  case "${arg}" in
    start) scale_to 1 ;;
    stop) scale_to 0 ;;
    status) ;;
    *)
      if ! is_int "${arg}" || ((10#${arg} == 0)); then
        die "Rate must be a positive integer (req/s), or one of start|stop|status. Got '${arg}'."
      fi
      set_rate "$((10#${arg}))"
      ;;
  esac
  status
}

main "$@"
