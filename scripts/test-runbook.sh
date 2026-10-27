#!/usr/bin/env bash
# End-to-end test of docs/runbook.md: reset, run every check, reset again.
#
#   scripts/test-runbook.sh [--no-slo-breach] [--wait MIN]
#
#   --no-slo-breach  skip scenario 4 (validate.sh criteria 9-10, ~3-5 min)
#   --wait MIN       minutes each fault runs before it is checked (default 2)
#
# Steps:
# 1. scripts/reset-demo.sh --full --no-fault
# 2. scripts/validate.sh 2-5,11-13 (stack, services, log/trace correlation, AI
#    roles, dashboards, secrets) and --scenarios 6-8 (scenario 1 onboarding,
#    latency alert, correlations for bad-version and errors)
# 3. Runbook checks validate.sh does not cover, with slow-db, bad-version and
#    errors injected together for --wait minutes:
#    R1 slow-db: pg_sleep span and "Slow ledger query" WARN log in one trace
#    R2 bad-version: "Ledger contract mismatch" ERROR log in a failing trace
#    R3 errors: fraud-check "Unhandled exception" log in a failing trace
#    R4 one trace has logs from all four base services (trace Logs tab)
#    R5 every ```esql block in docs/runbook.md runs and returns rows
#    R6 demo control panel answers
#    R7 bank UI answers via CloudFront, its API works, and an OTLP span posted to
#       its /v1/traces RUM endpoint reaches traces-* as web-banking-frontend
# 4. scripts/reset-demo.sh --full --keep-fx-rates --no-fault, then validate.sh
#    --slo-breach 9-10 (scenario 4 burn-rate alert and email)
# 5. scripts/reset-demo.sh --full (leaves the bad release on, ready for the
#    runbook). Always runs, also after a failure or Ctrl-C.
#
# UI-only steps (rendering, badges, AI answers) cannot be checked through the
# APIs; they are listed at the end. Typical run: 25-35 min.
# Result: results/test-runbook-<timestamp>.json. Exits 1 if any check FAILs.
set -euo pipefail

# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUN_SLO_BREACH=true
FAULT_WAIT_MIN=2
RUNBOOK="${REPO_ROOT}/docs/runbook.md"

usage() {
  print_header "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}

while (($# > 0)); do
  case "$1" in
    --no-slo-breach) RUN_SLO_BREACH=false; shift ;;
    --wait) FAULT_WAIT_MIN="${2:?--wait needs a value}"; shift 2 ;;
    -h | --help) usage 0 ;;
    *) error "Unknown argument: $1"; usage 1 ;;
  esac
done
is_int "${FAULT_WAIT_MIN}" || die "--wait must be an integer"

CHECKS_FILE="$(mktemp)"
VALIDATE_RESULTS=()
FINAL_RESET_DONE=false

final_reset() {
  local rc=$?
  if [[ "${FINAL_RESET_DONE}" != "true" ]]; then
    FINAL_RESET_DONE=true
    print_step "Final reset"
    "${SCRIPTS_DIR}/reset-demo.sh" --full || warn "Final reset reported problems; run scripts/reset-demo.sh --full"
  fi
  rm -f "${CHECKS_FILE}"
  exit "${rc}"
}
trap final_reset EXIT
trap 'exit 130' INT TERM

print_step() { printf '\n=== %s (%s) ===\n' "$1" "$(utc_now)" >&2; }

record() {
  local id="$1" status="$2" title="$3" detail="$4"
  printf '[%-4s] %s  %s\n' "${status}" "${id}" "${title}"
  [[ -n "${detail}" ]] && printf '%s\n' "${detail}" | sed 's/^/          /'
  jq -nc --arg id "${id}" --arg s "${status}" --arg t "${title}" --arg d "${detail}" \
    '{check: $id, status: $s, title: $t, detail: $d}' >>"${CHECKS_FILE}"
}

# run_validate ARGS...  -> runs validate.sh, keeps its result file, never fails the script
run_validate() {
  local out f
  out="$("${SCRIPTS_DIR}/validate.sh" "$@" 2>&1 | tee /dev/stderr)" || true
  f="$(sed -n 's/^Results: //p' <<<"${out}" | tail -n1)"
  [[ -n "${f}" && -f "${f}" ]] && VALIDATE_RESULTS+=("${f}")
  return 0
}

# esql_one QUERY  -> first row as a JSON object ({} if none or on error)
esql_one() { esql_rows "$1" 2>/dev/null | jq -c '.[0] // {}' 2>/dev/null || echo '{}'; }

# ---------------------------------------------------------------------------
# Runbook checks (step 3)
# ---------------------------------------------------------------------------
# Log queries skip the last 30 s (SETTLED): a log written mid-request is indexed before the request's
# spans, which are exported only when the request ends.
SETTLED='@timestamp < NOW() - 30 seconds'

check_slow_db() {
  local since="$1" logs tid row
  logs="$(esql_rows "FROM logs-*.otel-* | WHERE @timestamp >= TO_DATETIME(\"${since}\") AND ${SETTLED} AND service.name == \"accounts-ledger\"
    AND body.text LIKE \"Slow ledger query*\" AND trace.id IS NOT NULL | KEEP trace.id, body.text | LIMIT 5" 2>/dev/null || echo '[]')"
  [[ "$(jq 'length' <<<"${logs}" 2>/dev/null || echo 0)" != "0" ]] ||
    { record R1 FAIL "slow-db: slow span and WARN log in one trace" "no 'Slow ledger query' log with a trace.id since ${since}"; return; }
  for tid in $(jq -r '.[]["trace.id"]' <<<"${logs}"); do
    row="$(esql_one "FROM traces-*.otel-* | WHERE trace.id == \"${tid}\" AND attributes.db.statement LIKE \"*pg_sleep*\"
      | STATS spans = COUNT(*), max_ms = MAX(duration) / 1000000")"
    if (($(jq -r '.spans // 0' <<<"${row}") > 0)); then
      record R1 PASS "slow-db: slow span and WARN log in one trace" \
        "trace ${tid:0:8}...: pg_sleep span max $(jq -r '.max_ms | floor' <<<"${row}") ms; log '$(jq -r --arg t "${tid}" '[.[] | select(.["trace.id"] == $t)][0]["body.text"]' <<<"${logs}")'"
      return
    fi
  done
  record R1 FAIL "slow-db: slow span and WARN log in one trace" "'Slow ledger query' logs found, but none of their traces has a pg_sleep span"
}

# check_error_log ID TITLE SERVICE PATTERN SINCE  -> log matching PATTERN whose trace has an error span
check_error_log() {
  local id="$1" title="$2" svc="$3" pattern="$4" since="$5" tids tid errs
  tids="$(esql_rows "FROM logs-*.otel-* | WHERE @timestamp >= TO_DATETIME(\"${since}\") AND ${SETTLED} AND service.name == \"${svc}\"
    AND body.text LIKE \"${pattern}\" AND trace.id IS NOT NULL | KEEP trace.id | LIMIT 5" 2>/dev/null |
    jq -r '.[]["trace.id"]' 2>/dev/null || true)"
  [[ -n "${tids}" ]] || { record "${id}" FAIL "${title}" "no ${svc} log matching '${pattern}' with a trace.id since ${since}"; return; }
  for tid in ${tids}; do
    errs="$(esql_one "FROM traces-*.otel-* | WHERE trace.id == \"${tid}\" AND status.code == \"Error\" | STATS n = COUNT(*)" | jq -r '.n // 0')"
    if ((errs > 0)); then
      record "${id}" PASS "${title}" "trace ${tid:0:8}...: ${errs} error span(s) and the ${svc} log '${pattern}'"
      LAST_FAULT_TRACE="${tid}"
      return
    fi
  done
  record "${id}" FAIL "${title}" "${svc} logs matching '${pattern}' found, but none of their traces has an error span"
}

check_all_services_in_trace() {
  local since="$1" row
  row="$(esql_one "FROM logs-*.otel-* | WHERE @timestamp >= TO_DATETIME(\"${since}\") AND trace.id IS NOT NULL AND severity_text IS NOT NULL
    AND service.name IN (\"web-banking\", \"transfer-service\", \"fraud-check\", \"accounts-ledger\")
    | STATS services = COUNT_DISTINCT(service.name), lines = COUNT(*) BY trace.id | WHERE services >= 4 | LIMIT 1")"
  if [[ -n "$(jq -r '.["trace.id"] // empty' <<<"${row}")" ]]; then
    record R4 PASS "Trace Logs tab: one trace has logs from all four services" "trace $(jq -r '.["trace.id"][0:8]' <<<"${row}")...: $(jq -r .lines <<<"${row}") log lines"
  else
    record R4 FAIL "Trace Logs tab: one trace has logs from all four services" "no trace since ${since} with correlated logs from web-banking, transfer-service, fraud-check and accounts-ledger"
  fi
}

check_runbook_esql() {
  local tid="$1" n=0 bad=() details=() q out rows
  while IFS= read -r -d '' q; do
    n=$((n + 1))
    q="${q//<paste trace.id from the trace sample>/${tid}}"
    if out="$(esql_rows "${q}" 2>&1)"; then
      rows="$(jq 'length' <<<"${out}" 2>/dev/null || echo 0)"
      details+=("query ${n}: ${rows} row(s)")
      ((rows > 0)) || bad+=("query ${n} returned no rows: $(head -n2 <<<"${q}" | tr '\n' ' ')")
    else
      bad+=("query ${n} failed: $(grep -o '"reason":"[^"]*"' <<<"${out}" | head -n1)")
    fi
  done < <(awk '/^```esql$/ {inb=1; q=""; next} inb && /^```$/ {inb=0; printf "%s%c", q, 0; next} inb {q = q $0 "\n"}' "${RUNBOOK}")
  local detail
  detail="$(IFS=$'\n'; echo "${details[*]}")"
  if ((n == 0)); then
    record R5 FAIL "Runbook ES|QL queries run and return rows" "no esql blocks found in ${RUNBOOK#"${REPO_ROOT}/"}"
  elif ((${#bad[@]} == 0)); then
    record R5 PASS "Runbook ES|QL queries run and return rows" "${detail}"
  else
    record R5 FAIL "Runbook ES|QL queries run and return rows" "${detail}"$'\n'"$(IFS=$'\n'; echo "${bad[*]}")"
  fi
}

check_control_panel() {
  local url code
  url="$(tf_out_opt control_panel_url)"
  [[ -n "${url}" ]] || { record R6 FAIL "Demo control panel answers" "terraform output control_panel_url is empty"; return; }
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time 30 "${url}" || echo 000)"
  if [[ "${code}" == "200" ]]; then
    record R6 PASS "Demo control panel answers" "${url} -> HTTP ${code}"
  else
    record R6 FAIL "Demo control panel answers" "${url} -> HTTP ${code}"
  fi
}

check_bank_ui() {
  local url body code trace_id now payload found=0 i
  url="$(tf_out_opt web_banking_url)"
  [[ -n "${url}" ]] || { record R7 FAIL "Bank UI and RUM endpoint" "terraform output web_banking_url is empty"; return; }
  body="$(curl -s -w '\n%{http_code}' --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time 30 "${url}/" || echo 000)"
  code="${body##*$'\n'}"
  if [[ "${code}" != "200" ]] || ! grep -q "Demo Bank" <<<"${body}"; then
    record R7 FAIL "Bank UI and RUM endpoint" "${url}/ -> HTTP ${code}"; return
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time 30 "${url}/api/accounts/ACC-1001/balance" || echo 000)"
  [[ "${code}" == "200" ]] || { record R7 FAIL "Bank UI and RUM endpoint" "${url}/api/accounts/ACC-1001/balance -> HTTP ${code}"; return; }

  # Same request the browser exporter makes (OTLP/HTTP JSON, unsampled traceparent).
  trace_id="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  now="$(($(epoch_now) * 1000000000))"
  payload="$(jq -nc --arg t "${trace_id}" --arg s "$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')" --arg start "${now}" --arg end "$((now + 50000000))" '{
    resourceSpans: [{
      resource: {attributes: [
        {key: "service.name", value: {stringValue: "web-banking-frontend"}},
        {key: "telemetry.sdk.language", value: {stringValue: "webjs"}}]},
      scopeSpans: [{scope: {name: "test-runbook"}, spans: [{
        traceId: $t, spanId: $s, name: "R7 synthetic RUM span", kind: 1,
        startTimeUnixNano: $start, endTimeUnixNano: $end}]}]}]}')"
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time 30 \
    -H 'content-type: application/json' -H 'traceparent: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00' \
    --data "${payload}" "${url}/v1/traces" || echo 000)"
  [[ "${code}" == "200" ]] || { record R7 FAIL "Bank UI and RUM endpoint" "POST ${url}/v1/traces -> HTTP ${code}"; return; }

  for i in $(seq 1 12); do
    found="$(esql_one "FROM traces-*.otel-* | WHERE trace.id == \"${trace_id}\" AND service.name == \"web-banking-frontend\" | STATS c = COUNT(*)" | jq -r '.c // 0')"
    [[ "${found}" -gt 0 ]] && break
    sleep 10
  done
  if [[ "${found}" -gt 0 ]]; then
    record R7 PASS "Bank UI and RUM endpoint" "${url} -> UI and API HTTP 200; RUM span ${trace_id} indexed as web-banking-frontend"
  else
    record R7 FAIL "Bank UI and RUM endpoint" "RUM span ${trace_id} accepted (HTTP 200) but not in traces-*.otel-* after 2 min"
  fi
}

# ---------------------------------------------------------------------------
main() {
  require_cmd jq curl kubectl terraform awk
  load_env
  check_elastic
  ensure_kube
  mkdir -p "${RESULTS_DIR}"
  local ts started
  ts="$(utc_stamp)"
  started="$(utc_now)"

  print_step "1/5 Reset"
  "${SCRIPTS_DIR}/reset-demo.sh" --full --no-fault || warn "Reset reported problems; continuing"

  print_step "2/5 validate.sh: static checks and scenarios 1-2"
  run_validate --only 2,3,4,5,11,12,13
  run_validate --scenarios --wait "${FAULT_WAIT_MIN}" --only 6,7,8

  print_step "3/5 Runbook checks: slow-db + bad-version + errors for ${FAULT_WAIT_MIN} min"
  "${SCRIPTS_DIR}/fault-inject.sh" slow-db on >/dev/null
  "${SCRIPTS_DIR}/fault-inject.sh" errors on >/dev/null
  "${SCRIPTS_DIR}/fault-inject.sh" bad-version on >/dev/null
  local since
  since="$(utc_now)"
  sleep $((FAULT_WAIT_MIN * 60))
  LAST_FAULT_TRACE=""
  check_slow_db "${since}"
  check_error_log R2 "bad-version: contract mismatch ERROR log in a failing trace" transfer-service "Ledger contract mismatch*" "${since}"
  check_error_log R3 "errors: fraud-check exception log in a failing trace" fraud-check "Unhandled exception processing*" "${since}"
  check_all_services_in_trace "${since}"
  check_runbook_esql "${LAST_FAULT_TRACE:-none}"
  check_control_panel
  "${SCRIPTS_DIR}/fault-inject.sh" all off >/dev/null
  check_bank_ui

  if [[ "${RUN_SLO_BREACH}" == "true" ]]; then
    print_step "4/5 Reset (keep fx-rates), then scenario 4 SLO breach"
    "${SCRIPTS_DIR}/reset-demo.sh" --full --keep-fx-rates --no-fault || warn "Reset reported problems; continuing"
    run_validate --slo-breach --only 9,10
  else
    print_step "4/5 SLO breach skipped (--no-slo-breach)"
  fi

  local out_file="${RESULTS_DIR}/test-runbook-${ts}.json"
  jq -n --arg started "${started}" --arg finished "$(utc_now)" --arg kb "${KB_URL}" \
    --slurpfile own "${CHECKS_FILE}" \
    --argjson validate "$(if ((${#VALIDATE_RESULTS[@]} > 0)); then jq -s '[.[].checks[]]' "${VALIDATE_RESULTS[@]}"; else echo '[]'; fi)" '
    ($validate + $own) as $all | {
      started: $started, finished: $finished, kibana_url: $kb,
      summary: {
        pass: ($all | map(select(.status == "PASS")) | length),
        fail: ($all | map(select(.status == "FAIL")) | length),
        skip: ($all | map(select(.status == "SKIP")) | length)
      },
      failed: [$all[] | select(.status == "FAIL") | (.criterion // .check | tostring) + " " + .title],
      validate_checks: $validate, runbook_checks: $own
    }' >"${out_file}"

  print_step "5/5 Summary"
  jq -r '"PASS=\(.summary.pass) FAIL=\(.summary.fail) SKIP=\(.summary.skip)", (.failed[] | "  FAIL " + .)' "${out_file}"
  cat <<EOF
Results: ${out_file}

Check by eye during a rehearsal (no API for these):
  - Bank UI: a transfer in the browser shows web-banking-frontend as the root of the
    trace timeline, and on the service map in front of web-banking
  - Scenario 1: fx-rates node and edge on the service map
  - Scenario 2: alert badge on the service map, correlations ranking in the APM UI,
    trace sample Logs tab and Discover trace Logs section render
  - Scenario 3a: AI triage workflow runs, case contents and conversation link
    (needs the bad release: run after the final reset)
  - Scenario 3b: no AI entry points as demo-viewer; the triage conversation
    does not open for demo-viewer
  - Scenario 4: availability burn-rate alert from the bad release
    (scripts/detection-delay.sh measures it)
  - Scenario 5: dashboard edit visible in Kibana after terraform apply
EOF
  [[ "$(jq '.summary.fail' "${out_file}")" == "0" ]]
}

main
