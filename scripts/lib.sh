#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # constants are consumed by the scripts that source this file
#
# Shared helpers for the demo scripts. Source this file; do not execute it.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Secrets (elastic, demo user passwords) are read from `terraform output -json`
# and kept in shell variables only. They are never exported, never written to
# disk, and never passed on a command line: curl receives credentials through a
# config block on stdin (`-K -`).

if [[ -n "${_OBS_DEMO_LIB_LOADED:-}" ]]; then
  return 0
fi
_OBS_DEMO_LIB_LOADED=1

# ---------------------------------------------------------------------------
# Paths and constants (values from .claude/spec/interfaces.md)
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/scripts"
TF_DIR="${REPO_ROOT}/terraform"
ENV_FILE="${REPO_ROOT}/shared/env.json"
RESULTS_DIR="${REPO_ROOT}/results"

NAMESPACE="${DEMO_NAMESPACE:-banking}"
OTEL_NAMESPACE="opentelemetry-operator-system"
INSTRUMENTATION_REF="opentelemetry-operator-system/elastic-instrumentation"
ENVIRONMENT_NAME="banking-demo"
BASE_SERVICES=(web-banking transfer-service fraud-check accounts-ledger)
BASE_VERSION="1.4.2"
BAD_VERSION="2.0.0"
DEFAULT_LOAD_RATE=5
FAULT_CONFIGMAP="fault-config"

CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-10}"
CURL_MAX_TIME="${CURL_MAX_TIME:-60}"

# Populated by load_env
ES_URL=""
KB_URL=""
ELASTIC_USER=""
ELASTIC_PASSWORD=""
TF_OUTPUTS_JSON=""

# ---------------------------------------------------------------------------
# Logging (to stderr so stdout stays clean for data)
# ---------------------------------------------------------------------------
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
utc_stamp() { date -u +%Y%m%dT%H%M%SZ; }
epoch_now() { date -u +%s; }

_log() {
  local level="$1"
  shift
  printf '%s [%-5s] %s\n' "$(utc_now)" "${level}" "$*" >&2
}
info() { _log INFO "$@"; }
warn() { _log WARN "$@"; }
error() { _log ERROR "$@"; }
die() {
  _log ERROR "$@"
  exit 1
}

# ISO-8601 (UTC, optional fractional seconds) -> epoch seconds, portable (jq).
iso_to_epoch() {
  jq -nr --arg t "$1" '$t | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601'
}

# URL-encode a string
uri_encode() {
  jq -nr --arg s "$1" '$s | @uri'
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
require_cmd() {
  local missing=()
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]} > 0)); then
    die "Missing required command(s): ${missing[*]}. Install them and retry (see README.md, Prerequisites)."
  fi
}

# print_header FILE  -> the leading comment block of a script (usage text)
print_header() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$1"
}

is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# ---------------------------------------------------------------------------
# Terraform outputs
# ---------------------------------------------------------------------------
load_tf_outputs() {
  [[ -n "${TF_OUTPUTS_JSON}" ]] && return 0
  require_cmd terraform jq
  local out
  if ! out="$(terraform -chdir="${TF_DIR}" output -json 2>&1)"; then
    die "terraform output failed in ${TF_DIR}: ${out}"
  fi
  if [[ -z "${out}" || "${out}" == "{}" ]]; then
    die "No Terraform outputs found in ${TF_DIR}. Run 'terraform init' and 'terraform apply' first."
  fi
  TF_OUTPUTS_JSON="${out}"
}

# tf_out NAME  -> value (dies if the output is missing or empty)
tf_out() {
  local name="$1" val
  load_tf_outputs
  val="$(jq -r --arg k "${name}" \
    '.[$k].value // empty | if type == "string" then . else tojson end' <<<"${TF_OUTPUTS_JSON}")"
  [[ -n "${val}" ]] || die "Terraform output '${name}' is missing or empty. Has 'terraform apply' completed?"
  printf '%s' "${val}"
}

# tf_out_opt NAME [DEFAULT]  -> value or default
tf_out_opt() {
  local name="$1" def="${2:-}" val
  load_tf_outputs
  val="$(jq -r --arg k "${name}" \
    '.[$k].value // empty | if type == "string" then . else tojson end' <<<"${TF_OUTPUTS_JSON}")"
  printf '%s' "${val:-${def}}"
}

# Write non-secret values to shared/env.json. Existing keys are preserved;
# api_key is never written by these scripts.
cache_env() {
  local config_ready="false" tmp
  [[ -n "$(tf_out_opt slo_id)" ]] && config_ready="true"
  mkdir -p "$(dirname "${ENV_FILE}")"
  [[ -s "${ENV_FILE}" ]] || printf '{}\n' >"${ENV_FILE}"
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")"
  if jq --arg es "${ES_URL}" --arg kb "${KB_URL}" --argjson cr "${config_ready}" \
    '.elasticsearch_url = $es | .kibana_url = $kb | .infra_ready = true | .config_ready = $cr' \
    "${ENV_FILE}" >"${tmp}"; then
    mv "${tmp}" "${ENV_FILE}"
  else
    rm -f "${tmp}"
    warn "Could not update ${ENV_FILE} (invalid JSON?); continuing."
  fi
}

# set_env_flag KEY true|false
set_env_flag() {
  local key="$1" val="$2" tmp
  [[ -s "${ENV_FILE}" ]] || return 0
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")"
  if jq --arg k "${key}" --argjson v "${val}" '.[$k] = $v' "${ENV_FILE}" >"${tmp}"; then
    mv "${tmp}" "${ENV_FILE}"
  else
    rm -f "${tmp}"
  fi
}

# Load endpoints and credentials. Call once at the top of a script (not in a
# subshell) so the values are available to later $(...) calls.
load_env() {
  load_tf_outputs
  ES_URL="$(tf_out elasticsearch_url)"
  ES_URL="${ES_URL%/}"
  KB_URL="$(tf_out kibana_url)"
  KB_URL="${KB_URL%/}"
  ELASTIC_USER="$(tf_out_opt elastic_username elastic)"
  ELASTIC_PASSWORD="$(tf_out elastic_password)"
  NAMESPACE="$(tf_out_opt demo_namespace "${NAMESPACE}")"
  cache_env
}

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------
_curl_cfg_escape() {
  local s="${1//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "${s}"
}

# _curl_auth USER PASS curl-args...   (credentials go to curl via stdin config)
_curl_auth() {
  local user="$1" pass="$2"
  shift 2
  printf 'user = "%s:%s"\n' "$(_curl_cfg_escape "${user}")" "$(_curl_cfg_escape "${pass}")" |
    curl -sS -K - \
      --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
      --max-time "${CURL_MAX_TIME}" \
      "$@"
}

_require_endpoints() {
  [[ -n "${ES_URL}" && -n "${KB_URL}" && -n "${ELASTIC_PASSWORD}" ]] ||
    die "Endpoints not loaded. Call load_env first."
}

# kb_api METHOD PATH [BODY]  -> response body on stdout; non-zero on HTTP >= 400
kb_api() {
  _require_endpoints
  local method="$1" path="$2" body="${3:-}"
  local args=(-X "${method}" -H "kbn-xsrf: true" -H "Content-Type: application/json" --fail-with-body)
  [[ -n "${body}" ]] && args+=(--data-binary "${body}")
  _curl_auth "${ELASTIC_USER}" "${ELASTIC_PASSWORD}" "${args[@]}" "${KB_URL}${path}"
}

# es_api METHOD PATH [BODY]  -> response body on stdout; non-zero on HTTP >= 400
es_api() {
  _require_endpoints
  local method="$1" path="$2" body="${3:-}"
  local args=(-X "${method}" -H "Content-Type: application/json" --fail-with-body)
  [[ -n "${body}" ]] && args+=(--data-binary "${body}")
  _curl_auth "${ELASTIC_USER}" "${ELASTIC_PASSWORD}" "${args[@]}" "${ES_URL}${path}"
}

# kb_fetch METHOD PATH OUTFILE [BODY] [USER] [PASS]
#   Writes the body to OUTFILE and prints the HTTP status code (000 on
#   connection failure). Does not fail on HTTP errors: use when the status
#   code matters (404 detection, 403 checks).
kb_fetch() {
  _require_endpoints
  local method="$1" path="$2" outfile="$3" body="${4:-}"
  local user="${5:-${ELASTIC_USER}}" pass="${6:-${ELASTIC_PASSWORD}}"
  local args=(-X "${method}" -H "kbn-xsrf: true" -H "Content-Type: application/json"
    -o "${outfile}" -w '%{http_code}')
  [[ -n "${body}" ]] && args+=(--data-binary "${body}")
  local code
  code="$(_curl_auth "${user}" "${pass}" "${args[@]}" "${KB_URL}${path}" 2>/dev/null)" || true
  printf '%s' "${code:-000}"
}

# esql QUERY  -> raw ES|QL JSON response ({columns, values})
esql() {
  es_api POST "/_query?format=json" "$(jq -nc --arg q "$1" '{query: $q}')"
}

# esql_rows QUERY  -> JSON array of row objects
esql_rows() {
  local raw
  raw="$(esql "$1")" || {
    printf '%s\n' "${raw}" >&2
    return 1
  }
  jq -c '[.values[] as $r | [.columns, $r] | transpose | map({(.[0].name): .[1]}) | add // {}]' <<<"${raw}"
}

# untrack_demo_alerts  -> marks every active alert of the demo rules (tag banking-demo) as untracked by
# disabling each rule with untrack=true and enabling it again. Clears the Alerts page at once instead of
# waiting for recovery. A rule whose lookback window still holds fault data fires again on its next run.
untrack_demo_alerts() {
  local ids id failed=0
  ids="$(kb_api GET "/api/alerting/rules/_find?per_page=100&filter=$(uri_encode 'alert.attributes.tags:"banking-demo"')" |
    jq -r '.data[] | select(.enabled) | .id')" || return 1
  for id in ${ids}; do
    if kb_api POST "/api/alerting/rule/$(uri_encode "${id}")/_disable" '{"untrack":true}' >/dev/null &&
      kb_api POST "/api/alerting/rule/$(uri_encode "${id}")/_enable" >/dev/null; then
      info "  Rule ${id}: active alerts untracked"
    else
      error "  Rule ${id}: untrack failed (check that the rule is enabled in Kibana)"
      failed=1
    fi
  done
  return "${failed}"
}

# check_endpoint NAME URL  -> dies with guidance if the URL is unreachable.
# Any HTTP status (including 401) counts as reachable.
check_endpoint() {
  local name="$1" url="$2" code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
    --max-time 20 "${url}" 2>/dev/null || true)"
  if [[ -z "${code}" || "${code}" == "000" ]]; then
    die "${name} is unreachable at ${url}. Check network/VPN and DNS, that the Elastic Cloud deployment is running (Elastic Cloud console), and that 'terraform output' points to the current deployment."
  fi
  if [[ "${code}" =~ ^5 ]]; then
    die "${name} at ${url} returned HTTP ${code}. The deployment may be starting, restarting or unhealthy; retry in a few minutes."
  fi
}

check_elastic() {
  check_endpoint "Elasticsearch" "${ES_URL}"
  check_endpoint "Kibana" "${KB_URL}/api/status"
}

# ---------------------------------------------------------------------------
# Kubernetes helpers
# ---------------------------------------------------------------------------
kctl() {
  kubectl -n "${NAMESPACE}" "$@"
}

ensure_kube() {
  require_cmd kubectl
  if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    local hint="aws eks update-kubeconfig --name <cluster_name> --region <aws_region> --profile <aws_profile>"
    if [[ -n "${TF_OUTPUTS_JSON}" ]]; then
      hint="aws eks update-kubeconfig --name $(tf_out_opt cluster_name '<cluster_name>') --region $(tf_out_opt aws_region '<aws_region>') --profile $(tf_out_opt aws_profile '<aws_profile>')"
    fi
    die "Cannot reach namespace '${NAMESPACE}' with kubectl (context: $(kubectl config current-context 2>/dev/null || echo none)). Check AWS credentials and kubeconfig: ${hint}"
  fi
}

# fault_get KEY  -> current value in the fault ConfigMap
fault_get() {
  kctl get configmap "${FAULT_CONFIGMAP}" -o "jsonpath={.data.$1}" 2>/dev/null || true
}

# deploy_env DEPLOYMENT VAR  -> value of an env var on the first container
deploy_env() {
  kctl get deployment "$1" -o json 2>/dev/null |
    jq -r --arg v "$2" '.spec.template.spec.containers[0].env // [] | map(select(.name == $v)) | .[0].value // ""'
}

kibana_links() {
  local svc="${1:-}"
  printf '  Service inventory: %s/app/apm/services?environment=%s\n' "${KB_URL}" "${ENVIRONMENT_NAME}"
  printf '  Service map:       %s/app/apm/service-map?environment=%s\n' "${KB_URL}" "${ENVIRONMENT_NAME}"
  if [[ -n "${svc}" ]]; then
    printf '  Service page:      %s/app/apm/services/%s/overview?environment=%s\n' "${KB_URL}" "${svc}" "${ENVIRONMENT_NAME}"
  fi
  printf '  SLOs:              %s/app/slos\n' "${KB_URL}"
  printf '  Alerts:            %s/app/observability/alerts\n' "${KB_URL}"
}
