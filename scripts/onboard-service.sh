#!/usr/bin/env bash
# Scenario 1: self-service onboarding of fx-rates.
#
#   scripts/onboard-service.sh [install] [--timeout SEC]
#   scripts/onboard-service.sh uninstall
#
# install    helm upgrade --install fx-rates charts/fx-rates (OTel auto-instrumentation
#            annotation only), then poll Elasticsearch until fx-rates traces arrive
#            and print the elapsed time and Kibana links.
#            --timeout SEC  telemetry wait (default 600)
# uninstall  helm uninstall fx-rates (no-op if not installed)
set -euo pipefail

# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RELEASE="fx-rates"
SERVICE="fx-rates"
CHART_DIR="${REPO_ROOT}/charts/fx-rates"
TIMEOUT_SEC=600
POLL_SEC=15

usage() {
  print_header "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}

do_uninstall() {
  require_cmd helm kubectl
  ensure_kube
  if helm status "${RELEASE}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    info "Uninstalling Helm release ${RELEASE} from ${NAMESPACE}..."
    helm uninstall "${RELEASE}" -n "${NAMESPACE}" --wait >&2
    info "fx-rates removed. Its APM data remains until it ages out of the time picker."
  else
    info "Helm release ${RELEASE} is not installed in ${NAMESPACE}; nothing to do."
  fi
}

do_install() {
  require_cmd helm kubectl jq curl terraform
  [[ -f "${CHART_DIR}/Chart.yaml" ]] || die "Chart not found at ${CHART_DIR} (expected Chart.yaml)."
  load_env
  ensure_kube
  check_elastic

  local image start_iso start_epoch ready_epoch
  image="$(tf_out fx_rates_image)"
  start_iso="$(utc_now)"
  start_epoch="$(iso_to_epoch "${start_iso}")"

  info "Installing ${RELEASE} (image ${image}) into ${NAMESPACE} with instrumentation ${INSTRUMENTATION_REF}..."
  if ! helm upgrade --install "${RELEASE}" "${CHART_DIR}" -n "${NAMESPACE}" \
    --set "image=${image}" \
    --set "instrumentationRef=${INSTRUMENTATION_REF}" \
    --wait --timeout 5m >&2; then
    die "helm install failed. Inspect: kubectl -n ${NAMESPACE} get pods -l app.kubernetes.io/name=${RELEASE}; kubectl -n ${NAMESPACE} describe pods"
  fi
  ready_epoch="$(epoch_now)"
  info "Release ready after $((ready_epoch - start_epoch))s. Waiting for fx-rates traces in traces-*.otel-* (up to ${TIMEOUT_SEC}s)..."

  local query rows count=0 deadline=$((start_epoch + TIMEOUT_SEC))
  query="FROM traces-*.otel-* | WHERE service.name == \"${SERVICE}\" AND @timestamp >= TO_DATETIME(\"${start_iso}\") | STATS docs = COUNT(*), first_seen = MIN(@timestamp)"
  while (($(epoch_now) < deadline)); do
    if rows="$(esql_rows "${query}" 2>/dev/null)"; then
      count="$(jq -r '.[0].docs // 0' <<<"${rows}")"
      if ((count > 0)); then
        break
      fi
    fi
    sleep "${POLL_SEC}"
  done

  if ((count == 0)); then
    warn "No fx-rates traces after ${TIMEOUT_SEC}s. Check: the pod has the init container 'opentelemetry-auto-instrumentation-python' (kubectl -n ${NAMESPACE} get pod -l app.kubernetes.io/name=${RELEASE} -o jsonpath='{.items[0].spec.initContainers[*].name}'), the load generator is running (scripts/generate-load.sh status), and transfer-service is sending cross-currency transfers."
    exit 2
  fi

  local first_seen now
  first_seen="$(jq -r '.[0].first_seen // empty' <<<"${rows}")"
  now="$(epoch_now)"
  info "fx-rates telemetry arrived: ${count} trace docs. First span at ${first_seen:-unknown}."
  printf '\nOnboarding timeline\n'
  printf '  helm install started: %s\n' "${start_iso}"
  printf '  pods ready:           +%ss\n' "$((ready_epoch - start_epoch))"
  if [[ -n "${first_seen}" ]]; then
    printf '  first span indexed:   +%ss\n' "$(($(iso_to_epoch "${first_seen}") - start_epoch))"
  fi
  printf '  detected by script:   +%ss\n' "$((now - start_epoch))"
  printf '\nKibana\n'
  kibana_links "${SERVICE}"
  printf '\nNo Kibana changes were made: the SLO (groupBy service.name), alert rules and ML job pick fx-rates up automatically.\n'
}

main() {
  local cmd="install"
  if (($# > 0)) && [[ "$1" != --* ]]; then
    cmd="$1"
    shift
  fi
  while (($# > 0)); do
    case "$1" in
      --timeout) TIMEOUT_SEC="${2:?--timeout needs a value}"; shift 2 ;;
      -h | --help) usage 0 ;;
      *) error "Unknown argument: $1"; usage 1 ;;
    esac
  done
  is_int "${TIMEOUT_SEC}" || die "--timeout must be an integer (seconds)"
  case "${cmd}" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    -h | --help | help) usage 0 ;;
    *) usage 1 ;;
  esac
}

main "$@"
