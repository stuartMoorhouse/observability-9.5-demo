#!/usr/bin/env bash
# Validate the demo against acceptance criteria 2-14 (.claude/spec/spec.md).
#
#   scripts/validate.sh [--scenarios] [--slo-breach] [--all] [--only N[,N...]]
#
#   (default)     read-only checks: 2, 3, 4, 5, 10, 11, 12, 13 (6-9 SKIP, 14 SKIP)
#   --scenarios   also run 6 (installs fx-rates), 7 (latency fault) and
#                 8 (bad-version + errors faults), and an AI converse call for 11.
#                 Faults are turned off afterwards; fx-rates stays installed.
#   --slo-breach  also run 9 (scripts/slo-breach.sh, up to 30 min); 10 then
#                 requires a successful email action execution.
#   --all         --scenarios + --slo-breach
#   --only LIST   run only the listed criteria (e.g. --only 2,3,13)
#   --wait MIN    minutes to let faults accumulate for criterion 8 (default 4)
#
# Criterion 1 is 'terraform apply' itself. Criterion 14 is checked after
# 'terraform destroy' and is always SKIP here.
# Prints PASS/FAIL/SKIP per criterion, writes results/validate-<ts>.json and
# exits 1 if any check FAILs.
set -euo pipefail

# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUN_SCENARIOS=false
RUN_SLO_BREACH=false
ONLY=""
FAULT_WAIT_MIN=4
WINDOW="NOW() - 15 minutes"

usage() {
  print_header "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}

while (($# > 0)); do
  case "$1" in
    --scenarios) RUN_SCENARIOS=true; shift ;;
    --slo-breach) RUN_SLO_BREACH=true; shift ;;
    --all) RUN_SCENARIOS=true; RUN_SLO_BREACH=true; shift ;;
    --only) ONLY="${2:?--only needs a list}"; shift 2 ;;
    --wait) FAULT_WAIT_MIN="${2:?--wait needs a value}"; shift 2 ;;
    -h | --help) usage 0 ;;
    *) error "Unknown argument: $1"; usage 1 ;;
  esac
done
is_int "${FAULT_WAIT_MIN}" || die "--wait must be an integer"

# ---------------------------------------------------------------------------
# Result recording
# ---------------------------------------------------------------------------
CHECKS_FILE="$(mktemp)"
SCRATCH="$(mktemp -d)"
FAULTS_TOUCHED=false
RECORDED=0

cleanup() {
  local rc=$?
  if [[ "${FAULTS_TOUCHED}" == "true" ]]; then
    info "Restoring baseline: all faults off."
    "${SCRIPTS_DIR}/fault-inject.sh" all off >/dev/null 2>&1 ||
      warn "Could not turn faults off; run scripts/fault-inject.sh all off"
  fi
  rm -rf "${CHECKS_FILE}" "${SCRATCH}"
  exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

record() {
  local id="$1" status="$2" title="$3" detail="$4"
  printf '[%-4s] %2s  %s\n' "${status}" "${id}" "${title}"
  [[ -n "${detail}" ]] && printf '%s\n' "${detail}" | sed 's/^/          /'
  jq -nc --argjson id "${id}" --arg s "${status}" --arg t "${title}" --arg d "${detail}" \
    '{criterion: $id, status: $s, title: $t, detail: $d}' >>"${CHECKS_FILE}"
  RECORDED=$((RECORDED + 1))
}

selected() {
  [[ -z "${ONLY}" ]] && return 0
  [[ ",${ONLY}," == *",$1,"* ]]
}

# run_check ID TITLE FUNCTION  -- FUNCTION must call record exactly once
run_check() {
  local id="$1" title="$2" fn="$3" before="${RECORDED}"
  selected "${id}" || return 0
  CUR_ID="${id}"
  CUR_TITLE="${title}"
  "${fn}" || true
  if ((RECORDED == before)); then
    record "${id}" FAIL "${title}" "check aborted unexpectedly (see log above)"
  fi
}
pass() { record "${CUR_ID}" PASS "${CUR_TITLE}" "${1:-}"; }
fail() { record "${CUR_ID}" FAIL "${CUR_TITLE}" "${1:-}"; }
skip() { record "${CUR_ID}" SKIP "${CUR_TITLE}" "${1:-}"; }

# esql_count_by INDEX  -> JSON object {service: count} over the last 15 min
esql_count_by() {
  local rows
  rows="$(esql_rows "FROM $1 | WHERE @timestamp > ${WINDOW} | STATS c = COUNT(*) BY service.name | LIMIT 500" 2>/dev/null)" || {
    printf '{}'
    return 0
  }
  jq -c 'map({(.["service.name"] // "unknown"): .c}) | add // {}' <<<"${rows}"
}

# alert_since INDEX_PATTERN RULE_ID SINCE_ISO -> number of alerts started since
alert_since() {
  local body
  body="$(jq -nc --arg r "$2" --arg s "$3" '{size: 0, track_total_hits: true, query: {bool: {filter: [
    {term: {"kibana.alert.rule.uuid": $r}}, {range: {"kibana.alert.start": {gte: $s}}}]}}}')"
  es_api POST "/$(uri_encode "$1")/_search?ignore_unavailable=true&allow_no_indices=true&expand_wildcards=open,hidden" "${body}" 2>/dev/null |
    jq -r '.hits.total.value // 0' || printf '0'
}

pinned_version() {
  local f="${TF_DIR}/local.auto.tfvars"
  [[ -f "${f}" ]] || return 0
  sed -n 's/^[[:space:]]*elastic_version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${f}" | head -n1
}

# ---------------------------------------------------------------------------
# Criterion checks
# ---------------------------------------------------------------------------
check_2() {
  local health root nodes status version pinned ml_nodes ml_names
  health="$(es_api GET "/_cluster/health")" || { fail "cluster health request failed: ${health}"; return; }
  root="$(es_api GET "/")" || { fail "GET / failed: ${root}"; return; }
  nodes="$(es_api GET "/_nodes?filter_path=nodes.*.roles,nodes.*.name")" || { fail "GET _nodes failed"; return; }
  status="$(jq -r '.status' <<<"${health}")"
  version="$(jq -r '.version.number' <<<"${root}")"
  pinned="$(pinned_version)"
  ml_nodes="$(jq '[.nodes[]? | select(.roles | index("ml"))] | length' <<<"${nodes}")"
  ml_names="$(jq -r '[.nodes[]? | select(.roles | index("ml")) | .name] | join(", ")' <<<"${nodes}")"

  local problems=()
  [[ "${status}" == "green" ]] || problems+=("cluster status is ${status} (expected green)")
  if [[ -z "${pinned}" || "${pinned}" == *x* ]]; then
    [[ "${version}" == 9.5.* ]] || problems+=("version ${version} is not 9.5.x")
    pinned="${pinned:-not set in local.auto.tfvars}"
  else
    [[ "${version}" == "${pinned}" ]] || problems+=("version ${version} != pinned ${pinned}")
  fi
  ((ml_nodes > 0)) || problems+=("no node with the ml role")

  local detail
  detail="deployment_id=$(tf_out_opt deployment_id '?') status=${status} version=${version} pinned=${pinned} ml_nodes=${ml_nodes} (${ml_names:-none})"
  if ((${#problems[@]} == 0)); then pass "${detail}"; else fail "${detail}; $(IFS=';'; echo "${problems[*]}")"; fi
}

check_3() {
  local nodes not_ready total pods bad svc details=() problems=()
  nodes="$(kubectl get nodes -o json 2>&1)" || { fail "kubectl get nodes failed: ${nodes}"; return; }
  total="$(jq '.items | length' <<<"${nodes}")"
  not_ready="$(jq -r '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True") | not) | .metadata.name] | join(", ")' <<<"${nodes}")"
  details+=("nodes=${total}")
  ((total > 0)) || problems+=("no nodes")
  [[ -z "${not_ready}" ]] || problems+=("not Ready: ${not_ready}")

  pods="$(kctl get pods -o json 2>&1)" || { fail "kubectl get pods failed: ${pods}"; return; }
  bad="$(jq -r '[.items[] | select(.status.phase != "Running" and .status.phase != "Succeeded")
    | "\(.metadata.name)=\(.status.phase)"] | join(", ")' <<<"${pods}")"
  [[ -z "${bad}" ]] || problems+=("pods not Running: ${bad}")

  for svc in "${BASE_SERVICES[@]}" fx-rates; do
    local n inst
    n="$(jq --arg s "${svc}" '[.items[] | select(.metadata.name | startswith($s + "-")) | select(.status.phase == "Running")] | length' <<<"${pods}")"
    if ((n == 0)); then
      [[ "${svc}" == "fx-rates" ]] && continue
      problems+=("${svc}: no running pod")
      continue
    fi
    inst="$(jq --arg s "${svc}" '[.items[] | select(.metadata.name | startswith($s + "-")) | select(.status.phase == "Running")
      | select(any(.spec.initContainers[]?; .name | startswith("opentelemetry-auto-instrumentation")))] | length' <<<"${pods}")"
    details+=("${svc}: ${inst}/${n} pods auto-instrumented")
    ((inst == n)) || problems+=("${svc}: ${inst}/${n} pods have the operator init container")
  done

  # Static check: no OTel SDK dependency in application manifests.
  if [[ -d "${REPO_ROOT}/apps" ]]; then
    local sdk_hits
    sdk_hits="$(grep -rIl --include=package.json --include=requirements*.txt --include=pyproject.toml \
      --include=pom.xml --include=build.gradle* --include=*.csproj -i 'opentelemetry' "${REPO_ROOT}/apps" 2>/dev/null || true)"
    if [[ -n "${sdk_hits}" ]]; then
      problems+=("OTel SDK referenced in app manifests: ${sdk_hits//${REPO_ROOT}\//}")
    else
      details+=("no OpenTelemetry dependency in apps/ manifests")
    fi
  fi

  local detail
  detail="$(IFS=$'\n'; echo "${details[*]}")"
  if ((${#problems[@]} == 0)); then pass "${detail}"; else fail "${detail}"$'\n'"$(IFS=$'\n'; echo "${problems[*]}")"; fi
}

check_4() {
  local counts svc missing=() found=() map_note
  counts="$(esql_count_by 'traces-*.otel-*')"
  for svc in "${BASE_SERVICES[@]}"; do
    if [[ "$(jq -r --arg s "${svc}" '.[$s] // 0' <<<"${counts}")" -gt 0 ]]; then
      found+=("${svc}")
    else
      missing+=("${svc}")
    fi
  done

  # Service map: internal APM API (no public equivalent). Informational only.
  local start end tmp code
  start="$(date -u -r "$(($(epoch_now) - 900))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-15 min' +%Y-%m-%dT%H:%M:%SZ)"
  end="$(utc_now)"
  tmp="${SCRATCH}/servicemap.json"
  code="$(kb_fetch GET "/internal/apm/service-map?start=${start}&end=${end}&environment=${ENVIRONMENT_NAME}" "${tmp}")"
  if [[ "${code}" == "200" ]]; then
    local on_map=()
    for svc in "${BASE_SERVICES[@]}"; do
      grep -q "\"${svc}\"" "${tmp}" && on_map+=("${svc}")
    done
    map_note="service map API lists ${#on_map[@]}/${#BASE_SERVICES[@]}: ${on_map[*]:-none}"
  else
    map_note="service map not checked via API (HTTP ${code}); verify visually at ${KB_URL}/app/apm/service-map"
  fi

  local detail="traces in last 15 min: ${found[*]:-none}"$'\n'"${map_note}"
  if ((${#missing[@]} == 0)); then pass "${detail}"; else fail "${detail}"$'\n'"missing: ${missing[*]}"; fi
}

check_5() {
  local logs metrics traces svc problems=() details=()
  logs="$(esql_count_by 'logs-*.otel-*')"
  metrics="$(esql_count_by 'metrics-*.otel-*')"
  traces="$(esql_count_by 'traces-*.otel-*')"
  for svc in "${BASE_SERVICES[@]}"; do
    local l m t tid linked="no"
    l="$(jq -r --arg s "${svc}" '.[$s] // 0' <<<"${logs}")"
    m="$(jq -r --arg s "${svc}" '.[$s] // 0' <<<"${metrics}")"
    t="$(jq -r --arg s "${svc}" '.[$s] // 0' <<<"${traces}")"
    tid="$(esql_rows "FROM logs-*.otel-* | WHERE @timestamp > ${WINDOW} AND service.name == \"${svc}\" AND trace.id IS NOT NULL | KEEP trace.id | LIMIT 1" 2>/dev/null |
      jq -r '.[0]["trace.id"] // empty' 2>/dev/null || true)"
    if [[ -n "${tid}" ]]; then
      local tc
      tc="$(esql_rows "FROM traces-*.otel-* | WHERE trace.id == \"${tid}\" | STATS c = COUNT(*)" 2>/dev/null | jq -r '.[0].c // 0' 2>/dev/null || echo 0)"
      ((tc > 0)) && linked="yes (trace.id ${tid:0:8}... -> ${tc} spans)"
    fi
    details+=("${svc}: logs=${l} metrics=${m} traces=${t} log->trace=${linked}")
    ((l > 0)) || problems+=("${svc}: no logs")
    ((m > 0)) || problems+=("${svc}: no metrics")
    ((t > 0)) || problems+=("${svc}: no traces")
    [[ "${linked}" != "no" ]] || problems+=("${svc}: no log with a trace.id matching a trace")
  done
  local detail
  detail="$(IFS=$'\n'; echo "${details[*]}")"
  if ((${#problems[@]} == 0)); then pass "${detail}"; else fail "${detail}"$'\n'"$(IFS=$'\n'; echo "${problems[*]}")"; fi
}

check_6() {
  if [[ "${RUN_SCENARIOS}" != "true" ]]; then
    skip "opt-in: run with --scenarios (installs fx-rates)"
    return
  fi
  local out start_epoch problems=() details=()
  start_epoch="$(epoch_now)"
  if out="$("${SCRIPTS_DIR}/onboard-service.sh" install --timeout 300 2>&1)"; then
    details+=("fx-rates traces arrived within $(($(epoch_now) - start_epoch))s of install")
  else
    problems+=("onboard-service.sh failed or no traces within 300s: $(tail -n 3 <<<"${out}")")
  fi

  # SLO instance for fx-rates (public SLO API, fallback to SLO summary index).
  local slo_id slo_found=0 deadline kql
  slo_id="$(tf_out_opt slo_id)"
  if [[ -z "${slo_id}" ]]; then
    problems+=("terraform output slo_id is empty")
  else
    kql="slo.id:\"${slo_id}\" and slo.instanceId:\"fx-rates\""
    deadline=$(($(epoch_now) + 300))
    while (($(epoch_now) < deadline)); do
      slo_found="$(kb_api GET "/api/observability/slos?kqlQuery=$(uri_encode "${kql}")&perPage=10" 2>/dev/null |
        jq -r '.total // (.results | length) // 0' 2>/dev/null || echo 0)"
      if ((slo_found == 0)); then
        slo_found="$(es_api POST "/.slo-observability.summary-v3*/_search?ignore_unavailable=true&allow_no_indices=true&expand_wildcards=open,hidden" \
          "$(jq -nc --arg id "${slo_id}" '{size: 0, query: {bool: {filter: [{term: {"slo.id": $id}}, {term: {"slo.instanceId": "fx-rates"}}]}}}')" 2>/dev/null |
          jq -r '.hits.total.value // 0' 2>/dev/null || echo 0)"
      fi
      ((slo_found > 0)) && break
      sleep 20
    done
    if ((slo_found > 0)); then details+=("SLO ${slo_id} has an fx-rates instance"); else problems+=("no fx-rates instance of SLO ${slo_id} after 5 min"); fi
  fi

  # ML coverage: datafeeds started and not filtered to a fixed service list.
  local feeds started total filtered
  if feeds="$(es_api GET "/_ml/datafeeds/_stats" 2>/dev/null)"; then
    total="$(jq '.datafeeds | length' <<<"${feeds}")"
    started="$(jq '[.datafeeds[] | select(.state == "started")] | length' <<<"${feeds}")"
    filtered="$(es_api GET "/_ml/datafeeds" 2>/dev/null | jq -r '[.datafeeds[] | (.query | tostring)
      | select(test("transfer-service") and (test("fx-rates") | not))] | length' 2>/dev/null || echo 0)"
    details+=("ML datafeeds started ${started}/${total}")
    ((started > 0)) || problems+=("no started ML datafeed")
    ((filtered == 0)) || problems+=("an ML datafeed filters on a fixed service list that excludes fx-rates")
  else
    problems+=("could not read ML datafeed stats")
  fi

  local detail
  detail="$(IFS=$'\n'; echo "${details[*]}")"$'\n'"Note: fx-rates left installed; scripts/reset-demo.sh removes it."
  if ((${#problems[@]} == 0)); then pass "${detail}"; else fail "${detail}"$'\n'"$(IFS=$'\n'; echo "${problems[*]}")"; fi
}

check_7() {
  if [[ "${RUN_SCENARIOS}" != "true" ]]; then
    skip "opt-in: run with --scenarios (injects latency on transfer-service)"
    return
  fi
  local rule_id start start_epoch n=0 deadline
  rule_id="$(tf_out_opt latency_rule_id)"
  [[ -n "${rule_id}" ]] || { fail "terraform output latency_rule_id is empty"; return; }
  start="$(utc_now)"
  start_epoch="$(iso_to_epoch "${start}")"
  FAULTS_TOUCHED=true
  "${SCRIPTS_DIR}/fault-inject.sh" latency on >/dev/null 2>&1 || { fail "fault-inject.sh latency on failed"; return; }
  deadline=$((start_epoch + 360))
  while (($(epoch_now) < deadline)); do
    n="$(alert_since '.alerts-observability.*' "${rule_id}" "${start}")"
    ((n > 0)) && break
    sleep 15
  done
  local elapsed=$(($(epoch_now) - start_epoch))
  "${SCRIPTS_DIR}/fault-inject.sh" latency off >/dev/null 2>&1 || true
  local note="Service map alert badge: verify visually at ${KB_URL}/app/apm/service-map"
  if ((n > 0 && elapsed <= 300)); then
    pass "latency alert created after ~${elapsed}s (rule ${rule_id})"$'\n'"${note}"
  elif ((n > 0)); then
    fail "latency alert created after ~${elapsed}s (> 300s target)"
  else
    fail "no alert for latency rule ${rule_id} within 6 min"
  fi
}

# Failure rate of server spans by service.version for a service since START (ES|QL).
failure_by_version() {
  esql_rows "FROM traces-*.otel-* | WHERE @timestamp >= TO_DATETIME(\"$2\") AND service.name == \"$1\" AND kind == \"Server\"
    | EVAL failed = CASE(status.code == \"Error\", 1, 0)
    | STATS total = COUNT(*), failures = SUM(failed) BY service.version
    | EVAL rate = TO_DOUBLE(failures) / total
    | SORT rate DESC | LIMIT 10" 2>/dev/null || printf '[]'
}

check_8() {
  if [[ "${RUN_SCENARIOS}" != "true" ]]; then
    skip "opt-in: run with --scenarios (injects bad-version and errors faults)"
    return
  fi
  local problems=() details=() start rows base_rate bad_rate
  FAULTS_TOUCHED=true

  # bad-version: BAD_VERSION's failure rate should be well above BASE_VERSION's.
  # Baseline is the FAULT_WAIT_MIN window before the fault. The fault window starts after
  # fault-inject.sh has waited for the rollout, plus a grace period so spans from old pods
  # still terminating are excluded.
  start="$(jq -nr --argjson s $((FAULT_WAIT_MIN * 60)) 'now - $s | floor | todate')"
  rows="$(failure_by_version transfer-service "${start}")"
  base_rate="$(jq -r --arg v "${BASE_VERSION}" '[.[] | select(.["service.version"] == $v) | .rate][0] // 0 | . * 100 | floor' <<<"${rows}")"
  "${SCRIPTS_DIR}/fault-inject.sh" bad-version on >/dev/null 2>&1 || { fail "fault-inject.sh bad-version on failed"; return; }
  sleep 30
  start="$(utc_now)"
  info "Criterion 8: letting bad-version run for ${FAULT_WAIT_MIN} min..."
  sleep $((FAULT_WAIT_MIN * 60))
  rows="$(failure_by_version transfer-service "${start}")"
  bad_rate="$(jq -r --arg v "${BAD_VERSION}" '[.[] | select(.["service.version"] == $v) | .rate][0] // -1 | if . < 0 then -1 else . * 100 | floor end' <<<"${rows}")"
  details+=("transfer-service server-span failure rate: ${BASE_VERSION}=${base_rate}% (before), ${BAD_VERSION}=${bad_rate}% (during fault)")
  if ((bad_rate < 0)); then
    problems+=("no ${BAD_VERSION} server spans during bad-version fault")
  elif ((bad_rate < base_rate + 5)); then
    # BAD_RELEASE fails ~15% of transfers (TransferController); 5 points leaves room for sampling noise.
    problems+=("${BAD_VERSION} failure rate not at least 5 points above ${BASE_VERSION}")
  fi
  "${SCRIPTS_DIR}/fault-inject.sh" bad-version off >/dev/null 2>&1 || problems+=("bad-version off failed")

  # errors: fraud-check failure rate should rise well above baseline.
  start="$(utc_now)"
  "${SCRIPTS_DIR}/fault-inject.sh" errors on >/dev/null 2>&1 || { fail "fault-inject.sh errors on failed"; return; }
  info "Criterion 8: letting errors run for ${FAULT_WAIT_MIN} min..."
  sleep $((FAULT_WAIT_MIN * 60))
  rows="$(failure_by_version fraud-check "${start}")"
  local rate
  rate="$(jq -r '[.[] | .failures] | add // 0' <<<"${rows}")"
  local total
  total="$(jq -r '[.[] | .total] | add // 0' <<<"${rows}")"
  details+=("fraud-check failures ${rate}/${total} during errors fault")
  if ((total == 0)) || ((rate * 100 / total < 10)); then
    problems+=("fraud-check failure rate below 10% during errors fault")
  fi
  "${SCRIPTS_DIR}/fault-inject.sh" errors off >/dev/null 2>&1 || problems+=("errors off failed")

  local detail
  detail="$(IFS=$'\n'; echo "${details[*]}")"$'\n'"ES|QL proxy for APM correlations; confirm ranking in APM > transfer-service > Failed transaction correlations."
  if ((${#problems[@]} == 0)); then pass "${detail}"; else fail "${detail}"$'\n'"$(IFS=$'\n'; echo "${problems[*]}")"; fi
}

latest_breach_result() {
  find "${RESULTS_DIR}" -maxdepth 1 -name 'slo-breach-*.json' -print 2>/dev/null | sort | tail -n1
}

check_9() {
  local f
  if [[ "${RUN_SLO_BREACH}" != "true" ]]; then
    f="$(latest_breach_result)"
    if [[ -n "${f}" ]]; then
      skip "opt-in: run with --slo-breach. Last result ${f##*/}: alert_detected=$(jq -r .alert_detected "${f}") delay=$(jq -r .detection_delay_seconds "${f}")s"
    else
      skip "opt-in: run with --slo-breach (drives a burn-rate breach, up to 30 min)"
    fi
    return
  fi
  local out
  out="$("${SCRIPTS_DIR}/slo-breach.sh" 2>&1)" || true
  f="$(latest_breach_result)"
  if [[ -n "${f}" && "$(jq -r .alert_detected "${f}")" == "true" ]]; then
    pass "burn-rate alert after $(jq -r .detection_delay_seconds "${f}")s; result ${f#"${REPO_ROOT}/"}"
  else
    fail "no burn-rate alert detected. $(tail -n 3 <<<"${out}")"
  fi
}

check_10() {
  local rule_id rule email_actions body resp ok failed last
  rule_id="$(tf_out_opt burn_rate_rule_id)"
  [[ -n "${rule_id}" ]] || { fail "terraform output burn_rate_rule_id is empty"; return; }
  rule="$(kb_api GET "/api/alerting/rule/$(uri_encode "${rule_id}")" 2>/dev/null)" || { fail "rule ${rule_id} not readable via /api/alerting/rule"; return; }
  email_actions="$(jq '[.actions[]? | select(.connector_type_id == ".email")] | length' <<<"${rule}")"
  ((email_actions > 0)) || { fail "burn-rate rule has no .email action"; return; }

  # Connector execution log: Kibana event log (actions:execute events related to the rule).
  body="$(jq -nc --arg r "${rule_id}" '{
    size: 1, track_total_hits: true, sort: [{"@timestamp": "desc"}],
    query: {bool: {filter: [
      {term: {"event.provider": "actions"}}, {term: {"event.action": "execute"}},
      {nested: {path: "kibana.saved_objects", query: {bool: {filter: [
        {term: {"kibana.saved_objects.type": "alert"}}, {term: {"kibana.saved_objects.id": $r}}]}}}}]}},
    aggs: {outcome: {terms: {field: "event.outcome"}}}}')"
  resp="$(es_api POST "/.kibana-event-log-*/_search?ignore_unavailable=true&allow_no_indices=true&expand_wildcards=open,hidden" "${body}" 2>&1)" ||
    { fail "event log query failed: ${resp:0:300}"; return; }
  ok="$(jq '[.aggregations.outcome.buckets[]? | select(.key == "success") | .doc_count] | add // 0' <<<"${resp}")"
  failed="$(jq '[.aggregations.outcome.buckets[]? | select(.key == "failure") | .doc_count] | add // 0' <<<"${resp}")"
  last="$(jq -r '.hits.hits[0]._source | "\(.["@timestamp"]) \(.event.outcome) \(.message // "")"' <<<"${resp}" 2>/dev/null || true)"

  if ((ok > 0)); then
    pass "email action executions for burn-rate rule: success=${ok} failure=${failed}; last: ${last}"
  elif ((failed > 0)); then
    fail "email action executions all failed (${failed}); last: ${last}"
  elif [[ "${RUN_SLO_BREACH}" == "true" ]]; then
    fail "no email action execution recorded for rule ${rule_id} after the SLO breach run"
  else
    skip "no email action execution yet (rule has ${email_actions} email action(s)); run scripts/slo-breach.sh or --slo-breach"
  fi
}

check_11() {
  local sre_pw viewer_pw tmp code_sre code_viewer problems=() details=()
  sre_pw="$(tf_out_opt demo_sre_password)"
  viewer_pw="$(tf_out_opt demo_viewer_password)"
  [[ -n "${sre_pw}" && -n "${viewer_pw}" ]] || { fail "demo_sre_password / demo_viewer_password outputs missing"; return; }
  tmp="${SCRATCH}/ai.json"
  code_sre="$(kb_fetch GET "/api/agent_builder/agents" "${tmp}" "" demo-sre "${sre_pw}")"
  code_viewer="$(kb_fetch GET "/api/agent_builder/agents" "${tmp}" "" demo-viewer "${viewer_pw}")"
  details+=("GET /api/agent_builder/agents: demo-sre=HTTP ${code_sre}, demo-viewer=HTTP ${code_viewer}")
  [[ "${code_sre}" == "200" ]] || problems+=("demo-sre cannot use Agent Builder (HTTP ${code_sre})")
  [[ "${code_viewer}" == "403" || "${code_viewer}" == "404" ]] || problems+=("demo-viewer is not denied AI access (HTTP ${code_viewer})")

  if [[ "${RUN_SCENARIOS}" == "true" && "${code_sre}" == "200" ]]; then
    local code_conv
    code_conv="$(kb_fetch POST "/api/agent_builder/converse" "${tmp}" \
      '{"input":"Reply with the single word OK."}' demo-sre "${sre_pw}")"
    details+=("converse as demo-sre: HTTP ${code_conv}")
    [[ "${code_conv}" == "200" ]] || problems+=("AI converse as demo-sre failed (HTTP ${code_conv}): $(head -c 200 "${tmp}")")
  else
    details+=("AI response not exercised (use --scenarios for a converse call)")
  fi
  local detail
  detail="$(IFS=$'\n'; echo "${details[*]}")"
  if ((${#problems[@]} == 0)); then pass "${detail}"; else fail "${detail}"$'\n'"$(IFS=$'\n'; echo "${problems[*]}")"; fi
}

check_12() {
  local api files f id title tmp code problems=() details=()
  api="$(sed -n 's/^DASHBOARDS_API="\(.*\)".*/\1/p' "${SCRIPTS_DIR}/export-dashboard.sh")"
  [[ -n "${api}" ]] || { fail "could not read DASHBOARDS_API from export-dashboard.sh"; return; }
  shopt -s nullglob
  files=("${REPO_ROOT}"/dashboards/*.json)
  shopt -u nullglob
  ((${#files[@]} > 0)) || { fail "no dashboards/*.json in the repo"; return; }

  local first_id=""
  tmp="${SCRATCH}/dash.json"
  for f in "${files[@]}"; do
    id="$(jq -r '.id // empty' "${f}" 2>/dev/null || true)"
    [[ -n "${id}" ]] || id="$(basename "${f}" .json)"
    title="$(jq -r '.data.title // .title // empty' "${f}" 2>/dev/null || true)"
    code="$(kb_fetch GET "${api}/$(uri_encode "${id}")" "${tmp}")"
    if [[ "${code}" == "200" ]]; then
      local live_title
      live_title="$(jq -r '.data.title // .title // empty' "${tmp}")"
      if [[ -n "${title}" && "${live_title}" != "${title}" ]]; then
        problems+=("${f##*/}: Kibana title '${live_title}' != file title '${title}' (re-apply needed?)")
      else
        details+=("${f##*/}: present in Kibana (${id})")
      fi
      [[ -n "${first_id}" ]] || first_id="${id}"
    else
      problems+=("${f##*/}: GET ${api}/${id} returned HTTP ${code}")
    fi
  done

  if [[ -n "${first_id}" ]]; then
    local out_dir="${SCRATCH}/export"
    if "${SCRIPTS_DIR}/export-dashboard.sh" "${first_id}" --out-dir "${out_dir}" --slug roundtrip >/dev/null 2>&1 &&
      jq -e '.id and .data' "${out_dir}/roundtrip.json" >/dev/null 2>&1; then
      details+=("export round-trip of ${first_id}: valid JSON")
    else
      problems+=("export-dashboard.sh round-trip of ${first_id} failed")
    fi
  fi
  details+=("edit + re-apply: manual (change a title in dashboards/, terraform apply, re-run this check)")
  local detail
  detail="$(IFS=$'\n'; echo "${details[*]}")"
  if ((${#problems[@]} == 0)); then pass "${detail}"; else fail "${detail}"$'\n'"$(IFS=$'\n'; echo "${problems[*]}")"; fi
}

check_13() {
  require_cmd git
  local problems=() details=() tree="${SCRATCH}/tree" rc
  mkdir -p "${tree}"
  (cd "${REPO_ROOT}" && git ls-files -z -co --exclude-standard | tar --null -T - -cf -) | tar -xf - -C "${tree}"
  details+=("$(find "${tree}" -type f | wc -l | tr -d ' ') committed/committable files scanned")

  if (cd "${REPO_ROOT}" && git ls-files --error-unmatch terraform/local.auto.tfvars >/dev/null 2>&1); then
    problems+=("local.auto.tfvars is tracked by git")
  fi

  if command -v gitleaks >/dev/null 2>&1; then
    local out
    if gitleaks dir --help >/dev/null 2>&1; then
      out="$(gitleaks dir --no-banner --redact "${tree}" 2>&1)" && rc=0 || rc=$?
    else
      out="$(gitleaks detect --no-banner --redact --no-git --source "${tree}" 2>&1)" && rc=0 || rc=$?
    fi
    if ((rc == 0)); then details+=("gitleaks (working tree): clean"); else problems+=("gitleaks (working tree): $(tail -n 5 <<<"${out}")"); fi
    if gitleaks git --help >/dev/null 2>&1; then
      out="$(gitleaks git --no-banner --redact "${REPO_ROOT}" 2>&1)" && rc=0 || rc=$?
    else
      out="$(gitleaks detect --no-banner --redact --source "${REPO_ROOT}" 2>&1)" && rc=0 || rc=$?
    fi
    if ((rc == 0)); then details+=("gitleaks (git history): clean"); else problems+=("gitleaks (git history): $(tail -n 5 <<<"${out}")"); fi
  else
    details+=("gitleaks not installed: secret-pattern scan SKIPPED (install gitleaks)")
  fi

  # Personal values from local.auto.tfvars must not appear in committed files.
  # Only identifying keys are checked; region, versions, build options and the
  # org-wide tags (division, org, team, keep-until) are shared, not personal.
  local tfvars="${TF_DIR}/local.auto.tfvars" values=() v hits
  local personal_keys='elastic_cloud_organization|aws_profile|alert_email_recipients|owner|project'
  if [[ -f "${tfvars}" ]]; then
    while IFS= read -r v; do
      [[ ${#v} -ge 4 && "${v}" != "<"* ]] && values+=("${v}")
    done < <(sed -E 's/[[:space:]]*#.*$//' "${tfvars}" |
      grep -E "^[[:space:]]*(${personal_keys})[[:space:]]*=" |
      grep -Eo '"[^"]+"' | tr -d '"' | sort -u)
    for v in "${values[@]}"; do
      hits="$(grep -rIlF -- "${v}" "${tree}" 2>/dev/null | sed "s|${tree}/||" | grep -v '^terraform/local.auto.tfvars.example$' || true)"
      [[ -z "${hits}" ]] || problems+=("a personal value from local.auto.tfvars appears in: $(tr '\n' ' ' <<<"${hits}")")
    done
    details+=("${#values[@]} personal values from local.auto.tfvars checked")
  else
    details+=("local.auto.tfvars absent: personal-value scan skipped")
  fi

  # AWS account IDs in ARNs and non-example email addresses.
  hits="$(grep -rIEo 'arn:aws[a-z-]*:[a-z0-9-]*:[a-z0-9-]*:[0-9]{12}' "${tree}" 2>/dev/null | sed "s|${tree}/||" | head -n 5 || true)"
  [[ -z "${hits}" ]] || problems+=("AWS account IDs found: ${hits}")
  hits="$(grep -rIEoh '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "${tree}" 2>/dev/null |
    grep -Eiv '@(example\.(com|org|net)|anthropic\.com)$' | sort -u | head -n 5 || true)"
  [[ -z "${hits}" ]] || problems+=("email addresses found: $(tr '\n' ' ' <<<"${hits}")")

  local detail
  detail="$(IFS=$'\n'; echo "${details[*]}")"
  if ((${#problems[@]} == 0)); then pass "${detail}"; else fail "${detail}"$'\n'"$(IFS=$'\n'; echo "${problems[*]}")"; fi
}

check_14() {
  skip "run after 'terraform destroy': it must finish without a VPC DependencyViolation; then confirm no tagged resources remain (aws resourcegroupstaggingapi get-resources --tag-filters Key=keep-until)"
}

# ---------------------------------------------------------------------------
main() {
  require_cmd jq curl kubectl terraform tar
  load_env
  check_elastic
  ensure_kube
  mkdir -p "${RESULTS_DIR}"

  local ts started
  ts="$(utc_stamp)"
  started="$(utc_now)"
  info "Validating against ${KB_URL} (namespace ${NAMESPACE}); scenarios=${RUN_SCENARIOS} slo_breach=${RUN_SLO_BREACH}"
  printf '\n'

  run_check 2 "ECH healthy, pinned 9.5.x version, ML node present" check_2
  run_check 3 "EKS nodes Ready; demo pods Running and auto-instrumented" check_3
  run_check 4 "Base services in APM inventory and service map" check_4
  run_check 5 "Logs, metrics, traces per service via ES|QL; logs carry matching trace.id" check_5
  run_check 6 "fx-rates onboarding: inventory, SLO instance, ML coverage" check_6
  run_check 7 "Latency fault fires latency alert within 5 min" check_7
  run_check 8 "Correlations rank faulty service.version / attribute first" check_8
  run_check 9 "SLO burn-rate alert fires; detection delay recorded" check_9
  run_check 10 "Email action executed (connector run log success)" check_10
  run_check 11 "AI for demo-sre, no AI for demo-viewer" check_11
  run_check 12 "Dashboards from Git exist in Kibana; export round-trip" check_12
  run_check 13 "No personal values or secrets in committed files" check_13
  run_check 14 "terraform destroy clean (no DependencyViolation)" check_14

  local out_file="${RESULTS_DIR}/validate-${ts}.json"
  jq -s --arg started "${started}" --arg finished "$(utc_now)" \
    --argjson scen "${RUN_SCENARIOS}" --argjson breach "${RUN_SLO_BREACH}" --arg kb "${KB_URL}" '{
      started: $started, finished: $finished, kibana_url: $kb,
      options: {scenarios: $scen, slo_breach: $breach},
      summary: {
        pass: (map(select(.status == "PASS")) | length),
        fail: (map(select(.status == "FAIL")) | length),
        skip: (map(select(.status == "SKIP")) | length)
      },
      checks: .
    }' "${CHECKS_FILE}" >"${out_file}"

  local summary
  summary="$(jq -r '.summary | "PASS=\(.pass) FAIL=\(.fail) SKIP=\(.skip)"' "${out_file}")"
  printf '\n%s\nResults: %s\n' "${summary}" "${out_file}"
  [[ "$(jq '.summary.fail' "${out_file}")" == "0" ]]
}

main
