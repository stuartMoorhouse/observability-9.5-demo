# Demo Runbook: Elastic Observability 9.5 for Digital Banking

Persona: you are the on-call SRE for a retail bank's digital channels. The
customer-facing story is simple: customers make payment transfers in the web
banking app, and the bank needs to know, before customers complain, when
transfers slow down or fail, why, and who needs to act.

Application path: the bank's browser UI (`web-banking-frontend`, OpenTelemetry
browser RUM) -> `web-banking` (Node.js) -> `transfer-service` (Java) ->
`fraud-check` (.NET) and `accounts-ledger` (Python, Postgres). `fx-rates`
(Python) is onboarded live in scenario 1. Environment: `banking-demo`.

All scripts run from the repo root and read endpoints and credentials from
`terraform output` in `terraform/`. Run the `terraform` commands below from
`terraform/` (or add `-chdir=terraform`).

While presenting, use the demo control panel
(`terraform output -raw control_panel_url`) instead of the terminal. It has a
button for every `fault-inject.sh`, `onboard-service.sh` and `generate-load.sh`
command below, plus a plain reset. `slo-breach.sh` (measured detection delay)
and `reset-demo.sh --full` still need the terminal. See the README,
"Demo control panel".

## Before the meeting (T-60 min)

1. `scripts/validate.sh` - all read-only checks PASS (criterion 9/10 may SKIP).
   For a full rehearsal by script, run `scripts/test-runbook.sh` instead
   (~25-35 min): it resets, drives every scenario through the APIs, checks
   the runbook's ES|QL queries and log correlation, and resets again. It
   lists the UI-only steps to check by eye at the end.
2. `scripts/reset-demo.sh --full` - baseline state, fx-rates removed, active
   alerts cleared. You can start presenting as soon as it finishes. It takes
   ~30 s, or up to ~6 min when a fault ran in the last few minutes (it waits
   for burn-rate alerts to recover so they do not fire again mid-demo).
3. `scripts/fault-inject.sh status` - every fault off, `APP_VERSION=1.4.2`.
4. Log in to Kibana in three browser profiles:
   - `elastic` (superuser, for setup only) - `terraform output -raw elastic_password`
   - `demo-sre` - `terraform output -raw demo_sre_password`
   - `demo-viewer` - `terraform output -raw demo_viewer_password`
5. Present as `demo-sre`. Set the time picker to **Last 15 minutes**,
   refresh every 10 s.
6. Open tabs: the bank UI (`terraform output -raw web_banking_url`),
   Observability > Applications > Service inventory, Service map, SLOs,
   Alerts, Discover (ES|QL), Dashboards. Send one transfer in the bank UI so
   `web-banking-frontend` is on the service map.
7. If the SLO budget is depleted from rehearsals, reset it (SLOs > select the
   SLO > Actions > Reset).

Timing guide: the full flow is ~45 minutes. Scenarios 2 and 4 share one fault
window, so start `scripts/slo-breach.sh --keep-fault` early (see scenario 4).

Quick demo (~15 min): scenarios 1 and 2 only. Inject the scenario 2 fault
when you start scenario 1; by the time onboarding is done the alert and
correlations are ready.

Rule timings are tuned for demos (`terraform/modules/kibana-content/rules.tf`):
threshold rules look at the last 1 minute, the fastest burn-rate window is
5 min long / 1 min short, and every short window is 1 min. Alerts
fire and recover in minutes. These are not production settings.

---

## Scenario 1: Self-service Kubernetes onboarding (~7 min)

**Message:** a new team ships a service to the cluster and gets full
observability, SLO coverage, alerting and anomaly detection without opening a
ticket or touching Kibana.

| Step | Action | Talk track |
|---|---|---|
| 1 | Show Service inventory: 4 services, environment `banking-demo`. | "These are today's payment services. None of them contains an OpenTelemetry SDK; the OTel Operator injects instrumentation at pod start." |
| 2 | Show `charts/fx-rates/templates/fx-rates.yaml` (the annotation `instrumentation.opentelemetry.io/inject-python`). | "This annotation is the only observability configuration the fx-rates team adds. That is the platform contract." |
| 3 | Run `scripts/onboard-service.sh` | "Helm install, exactly as the team would do in their pipeline." |
| 4 | While it waits (pods ready ~30-60 s, first spans typically 1-3 min): Infrastructure > Kubernetes, filter namespace `banking`, show the new pod. | "The node and pod views pick up the new workload from the EDOT DaemonSet; nothing to register." |
| 5 | Script prints elapsed time and links. Refresh Service inventory: `fx-rates` appears. Open Service map: `transfer-service -> fx-rates` edge. | "Discovered from traces. The dependency on fx-rates is drawn because transfer-service now calls it for cross-currency transfers." |
| 6 | SLOs: open the transfer latency/availability SLO, show the instance list grouped by `service.name`, find `fx-rates` (may take ~5 min to appear). | "The SLO was defined once, grouped by service. New services inherit an SLO instance." |
| 7 | Stack Management > Rules: show the latency rule grouped by `service.name`. Machine Learning > Anomaly Detection: job covers all services in the environment. | "Same for alerting and ML: rules and jobs are scoped to the environment, not a hard-coded service list." |

Fallback: if fx-rates traces are slow, check `scripts/generate-load.sh status`
and the pod init container (`kubectl -n banking get pod -l app.kubernetes.io/name=fx-rates -o jsonpath='{.items[0].spec.initContainers[*].name}'`).

---

## Scenario 2: Incident to root cause (~10 min)

**Message:** from an alert to the line of evidence in a few clicks, across
services written in four languages, with the application logs of every
request correlated to its trace.

Pick one fault per run and start it 3-5 minutes before you need it (for the
quick demo: at the start of scenario 1). Each fault has its own walkthrough
below. Recommended order for a first meeting: bad release (best correlation
story), then slow database (best trace waterfall story).

| Fault | Command | Visible after |
|---|---|---|
| [Bad release of transfer-service](#bad-release-of-transfer-service) | `scripts/fault-inject.sh bad-version on` | new version ~1-2 min, correlations ~3-5 min |
| [Slow database in accounts-ledger](#slow-database-in-accounts-ledger) | `scripts/fault-inject.sh slow-db on` | slow DB spans and WARN logs ~1 min |
| [Latency on transfer-service](#latency-on-transfer-service) | `scripts/fault-inject.sh latency on 1500` | alert ~1-2 min |
| [Errors in fraud-check](#errors-in-fraud-check) | `scripts/fault-inject.sh errors on 30` | error rate ~1 min, alert ~1-2 min |

Every walkthrough starts in the bank UI (`terraform output -raw web_banking_url`).
To open the trace of your own transfer: APM > service `web-banking-frontend` >
transaction `Submit transfer` > latest sample. The browser span is the root,
above `web-banking`.

### Bad release of transfer-service

Start: `scripts/fault-inject.sh bad-version on` (control panel > Bad release
**On**). transfer-service rolls out version `2.0.0` with a simulated ledger
contract regression: every transfer is ~0.4 s slower and about 15% fail with
HTTP 500.

| Step | Action | Talk track |
|---|---|---|
| 1 | Bank UI: send a few transfers. They are slower, and some end in "Transfer failed". | "This is what the customer sees. Every click is traced in the browser, so the trace starts here, not at the first server." |
| 2 | Observability > Alerts: the error-rate alert for `transfer-service`. Open the alert details. | "Customers' transfers are failing. We were told by the platform, not by the contact centre." |
| 3 | Service map (environment `banking-demo`): alert badge on `transfer-service`; SLO and anomaly indicators on the service. Click the node > Service details. | "One view tells us which hop is unhealthy and whether it is burning the SLO." |
| 4 | Service overview: latency and failed transaction rate charts. Version `2.0.0` appears next to `1.4.2`. | "A new version went out at the same time the regression started." |
| 5 | Transactions > `POST /transfer` > **Failed transaction correlations** (and **Latency correlations**). | "Elastic compares failed transactions with healthy ones and ranks the attributes that explain the difference. Here `service.version: 2.0.0` is at the top." |
| 6 | Pick a failed sample > **Trace waterfall**. Open the span error: `LedgerContractMismatchException` ("Ledger response missing field 'postingId' (contract v2)"). The transfer fails before it reaches fraud-check or the ledger. | "End-to-end trace, and the exact line of the new release that fails." |
| 7 | Still on the trace sample, open the **Logs** tab (next to Timeline and Metadata): the `ERROR Ledger contract mismatch ...` line from transfer-service and the `transfer failed` line from web-banking for the same request. | "These are the application logs for this one request. No SDK code in the apps, no log parsing: the EDOT agents write the trace id on every log record." |
| 8 | Click a log line > open its details > **trace.id** / "View trace" to go from log back to the trace. | "It works both ways: whoever starts from a log line gets the full request in one click." |
| 9 | Discover, ES|QL `FROM traces-*` (or a `traces-*` data view). Filter to a failing transfer (`service.name == "transfer-service" AND status.code == "Error"`), expand a row. The **Overview** tab shows the trace summary and a **Logs** section with the correlated logs; **Open in Discover** opens them as a log list (technical preview). | "The same correlation in Discover, for teams that live in logs and traces rather than the APM UI." |
| 10 | Discover > ES|QL: run the first and third [queries below](#esql-queries-all-faults) (failures and p95 by `service.version`, errors by version). | "And when the out-of-the-box views are not enough, every signal is queryable with one language." |

### Slow database in accounts-ledger

Start: `scripts/fault-inject.sh slow-db on` (control panel > Slow DB **On**).
accounts-ledger adds `pg_sleep(0.8)` to balance lookups and a slow
duplicate-reference scan to every debit and credit: balances take ~0.8 s
longer and transfers ~1.6 s longer. Nothing fails.

| Step | Action | Talk track |
|---|---|---|
| 1 | Bank UI: refresh the balance and send a transfer. Both succeed, but are noticeably slow. | "Nothing is broken, it is just slow: the kind of problem customers notice before most monitoring does." |
| 2 | Observability > Alerts: the latency alert for `accounts-ledger`, and for `transfer-service` and `web-banking`, which wait on it. | "Three services alerting, one cause. Which one?" |
| 3 | Service map: alert badges along the chain. `accounts-ledger` is the deepest unhealthy service, next to its Postgres dependency. Click it > Service details. | "The map shows where the slowness starts." |
| 4 | Pick a slow sample > **Trace waterfall** (or your transfer from step 1). Expand the `accounts-ledger` span and its Postgres child span: the statement contains `pg_sleep`. | "End-to-end trace across Node, Java, .NET and Python, and the exact query where the time goes." |
| 5 | Open the **Logs** tab: `WARN Slow ledger query: ... took N ms (threshold 500 ms)` from accounts-ledger, alongside the lines from every other service in the trace (web-banking `transfer processed`, fraud-check `Scored transfer ...`, accounts-ledger `Posted debit ...`). | "These are the application logs for this one request, from all four services and languages. No SDK code in the apps, no log parsing." |
| 6 | Click the WARN line > **trace.id** / "View trace" to go back to the trace. | "Whoever starts from the log line gets the full request in one click." |
| 7 | Discover > ES|QL: run the second and fourth [queries below](#esql-queries-all-faults) (all logs for this trace, pod CPU). | "Pod CPU is flat: the database is waiting, not short of resources. Adding nodes would not fix it." |

### Latency on transfer-service

Start: `scripts/fault-inject.sh latency on 1500` (control panel > Latency
**On**). transfer-service waits 1500 ms on every transfer before doing any
work. Balance checks do not go through transfer-service and are unaffected.

| Step | Action | Talk track |
|---|---|---|
| 1 | Bank UI: send a transfer (1.5 s or more), then refresh the balance (fast). | "Only transfers are slow, so the problem is on the transfer path." |
| 2 | Observability > Alerts: the latency alert for `transfer-service`, and for `web-banking`, which waits on it. | "The platform told us before the contact centre did." |
| 3 | Service map: alert badge on `transfer-service`; its dependencies `fraud-check` and `accounts-ledger` are healthy. | "The services it calls are fine, so the time is spent inside transfer-service." |
| 4 | Pick a slow sample > **Trace waterfall**. The `POST /transfer` span in transfer-service is ~1.5 s long, but its calls to fraud-check and accounts-ledger take their normal time; the gap before the first child call is the delay. | "The trace rules out every downstream service in one look." |
| 5 | Discover > ES|QL: `FROM logs-*.otel-* \| WHERE service.name == "transfer-service" AND body.text LIKE "Fault config changed*"`. The `Fault config changed: LATENCY_MS=1500` line marks the moment it started. | "In a real incident this is the config change or deploy you look for at the start of the regression." |

### Errors in fraud-check

Start: `scripts/fault-inject.sh errors on 30` (control panel > Errors **On**).
30% of fraud-check calls hang for 200-600 ms and then fail with HTTP 500
(`FraudModelTimeoutException`). The transfer fails with them.

| Step | Action | Talk track |
|---|---|---|
| 1 | Bank UI: send a few transfers. About one in three ends in "Transfer failed" (HTTP 500). | "Some customers can't pay. Which ones, and why?" |
| 2 | Observability > Alerts: the error-rate alerts for `fraud-check`, `transfer-service` and `web-banking`. | "Three services alerting; the errors start at one of them." |
| 3 | Service map: `fraud-check` is the deepest service with an alert badge. Click it > Service details. | "The errors start at fraud-check and travel up the call chain." |
| 4 | fraud-check > **Errors**: the `FraudModelTimeoutException` group, with its occurrences over time. | "Errors are grouped by type, with the stack trace and the first and last time seen." |
| 5 | Open a failed sample > **Trace waterfall** (or your failed transfer from step 1). The error on the fraud-check span becomes an HTTP 500 in transfer-service, web-banking and the browser. | "One trace shows the whole blast radius, from the fraud model to the customer's screen." |
| 6 | Open the **Logs** tab: `Unhandled exception processing /score` from fraud-check, and the failure as it surfaced in web-banking (`transfer failed`). | "The logs for this one request, from every service, without searching." |
| 7 | Discover > ES|QL: run the third [query below](#esql-queries-all-faults) (errors by service and version). | "Every signal is queryable with one language." |

### ES|QL queries (all faults)

Paste into Discover, mode ES|QL:

```esql
FROM traces-*.otel-*
| WHERE service.name == "transfer-service" AND @timestamp > NOW() - 30 minutes
| EVAL failed = CASE(status.code == "Error", 1, 0)
| STATS requests = COUNT(*), failures = SUM(failed), p95_ms = PERCENTILE(duration, 95) / 1000000
    BY service.version, bucket = BUCKET(@timestamp, 1 minute)
| SORT bucket DESC
```

```esql
FROM logs-*.otel-*
| WHERE trace.id == "<paste trace.id from the trace sample>" AND severity_text IS NOT NULL
| KEEP @timestamp, service.name, severity_text, body.text
| SORT @timestamp ASC
```

```esql
FROM logs-*.otel-*
| WHERE service.name IN ("transfer-service", "fraud-check") AND severity_text IN ("ERROR", "Error")
| STATS errors = COUNT(*) BY service.name, service.version
| SORT errors DESC
```

```esql
FROM metrics-*.otel-*
| WHERE k8s.namespace.name == "banking" AND @timestamp > NOW() - 30 minutes
| STATS cpu = AVG(k8s.pod.cpu.usage) BY k8s.pod.name
| SORT cpu DESC
| LIMIT 10
```

Field names follow the OTel-native mappings in 9.5 (`duration` is in
nanoseconds). Adjust if a field is named differently on your stack.

### How log correlation works

Each EDOT SDK (Java, .NET, Node.js, Python)
exports the application's log records over OTLP with `trace_id` and `span_id`
from the active span. The APM Logs tab and Discover's trace view filter
`logs-*` on that trace id. Container stdout is also collected by the
`filelog` receiver, but those copies have no trace id and do not appear in
the correlated views. Per-service settings:

| Service | Logging library | What turns on log export |
|---|---|---|
| transfer-service | Logback (Spring Boot) | EDOT Java default |
| fraud-check | `ILogger` | EDOT .NET default (do not call `ClearProviders()`) |
| web-banking | pino | `ELASTIC_OTEL_NODE_ENABLE_LOG_SENDING=true` (opt-in in EDOT Node) |
| accounts-ledger, fx-rates | `logging` | `OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true` |

End of scenario: `scripts/fault-inject.sh <mode> off` (or leave it on for
scenario 3).

---

## Scenario 3: AI-assisted triage, AI off, per-role restriction (~8 min)

**Message:** AI shortens triage for the SRE, but the platform is fully
useful without it, and the bank decides who gets AI.

Keep the fault from scenario 2 running.

| Step | Action | Talk track |
|---|---|---|
| 1 | As `demo-sre`, open the alert from scenario 2 and start the **AI Assistant** from the alert ("Help me understand this alert"), or open **Agent Builder > Agents** and chat with the observability agent. | "The LLM is the Elastic Managed LLM, already part of this deployment. No external key, no data leaving the provider boundary we already approved." |
| 2 | Prompt: "Investigate the latency alert on transfer-service in banking-demo over the last 30 minutes. Find the root cause and suggest next steps." The agent uses the observability investigation skill: it reads alerts, SLOs, service dependencies, correlations, traces and logs. | "It runs the same steps we just did by hand: alert, service map, correlations, trace, logs. And it shows its tool calls so the SRE can check the evidence." |
| 3 | Follow up: "Write an ES|QL query that shows the error rate by service.version for transfer-service." Run it in Discover. | "Output the SRE can verify and reuse." |
| 4 | **AI off:** switch to the `demo-viewer` browser profile. Show the same alert, service map, correlations, trace waterfall and logs. Point out there is no AI Assistant button and Agent Builder is not in the navigation. | "Everything we used for root cause in scenario 2 is core functionality. AI is an accelerator, not a dependency." |
| 5 | Explain the control: Stack Management > Roles > `demo-viewer` (Observability read, no AI Assistant / Agent Builder privileges) vs `demo-sre`. Both roles and users are created by Terraform. | "Access to AI is a role privilege. It can follow your approval process: team by team, space by space, or off entirely." |

Optional: show the role definitions in `terraform/modules/kibana-content` to make the
point that the restriction is code-reviewed.

---

## Scenario 4: SLO burn-rate alerting (~8 min, plus lead time)

**Message:** alert on what customers feel (the error budget), not on noisy
thresholds, and measure how fast the platform detects a real breach.

Lead time: start the breach ~5 minutes before this scenario, for example at
the start of scenario 3:

```bash
scripts/slo-breach.sh --keep-fault
```

It records the fault start (UTC), injects 3000 ms latency on
`transfer-service`, polls the SLO alerts index every 15 s for the burn-rate
rule from `terraform output burn_rate_rule_id`, and writes
`results/slo-breach-<timestamp>.json` with `fault_start`, `alert_detected`
and `detection_delay_seconds`. Typical delay: ~4 minutes (5 min / 1 min
fast-burn window, SLO transform delay, 1 min rule interval). Without `--keep-fault` the fault
is turned off when the script exits.

| Step | Action | Talk track |
|---|---|---|
| 1 | Observability > SLOs: the transfer SLO, grouped by `service.name`. Show the target, time window and remaining error budget for `transfer-service`. | "The objective is defined in customer terms: transfers complete within the latency target, 99% of the time." |
| 2 | Open the SLO: SLI chart, error budget burn-down. Show the burn-rate rule linked to it (multi-window, fast and slow burn). | "We page when we are spending the budget fast enough to run out, not every time one request is slow." |
| 3 | Alerts: the burn-rate alert. Open it: burn rate, windows, reason. | "This is the alert that would wake someone up." |
| 4 | Show the email notification (email connector, recipients from `alert_email_recipients`), and Stack Management > Connectors > email connector > execution log: success. | "Delivered through the Elastic Cloud email service. Same mechanism can call PagerDuty, ServiceNow or a webhook." |
| 5 | Show `results/slo-breach-<timestamp>.json`: `detection_delay_seconds`. | "Measured, not claimed: from fault injection to alert in this many seconds." |
| 6 | Drill-through: from the SLO details, open the underlying events (APM service page for `transfer-service` filtered to the SLO window, or **View in Discover**). | "From the budget straight to the slow transactions that consumed it." |

End: `scripts/fault-inject.sh latency off`.

---

## Scenario 5: Observability as code (~7 min)

**Message:** dashboards, SLOs, rules and roles live in Git and go through the
same review and deployment process as the infrastructure.

| Step | Action | Talk track |
|---|---|---|
| 1 | Show `dashboards/` in the repo and the Terraform resource that deploys it through the Kibana Dashboards API on `terraform apply` (re-runs when a file changes). | "This JSON is the dashboard. It is reviewed in a pull request like any other change." |
| 2 | Kibana > Dashboards: open the banking dashboard. | |
| 3 | Edit a file in `dashboards/` (for example change a panel title), then `git diff`, `git commit`, `terraform apply` (only the dashboard resource changes; ~30 s). Refresh Kibana. | "Commit, apply, visible. Same flow in every environment." |
| 4 | In Kibana, create or edit a dashboard by hand (add a panel), save it. | "Teams can still prototype in the UI." |
| 5 | `scripts/export-dashboard.sh "<dashboard title>"` - writes `dashboards/<slug>.json`, normalised (server metadata stripped, keys sorted) so diffs are clean. Show `git diff --stat`. | "And bring it back into Git with one command, ready for review." |
| 6 | Mention the rest is code too: SLOs, burn-rate and threshold rules, the email connector, the ML job, roles and users are Terraform resources (`elasticstack` provider). | "Nothing in this demo was clicked together." |

Revert the demo edit afterwards (`git checkout -- dashboards/` and
`terraform apply`) if you do not want to keep it.

---

## Reset

Between runs:

```bash
scripts/reset-demo.sh          # faults off, APP_VERSION=1.4.2 BAD_RELEASE=false, fx-rates removed, load 5 req/s
scripts/fault-inject.sh status
```

- Active alerts recover on their own: threshold alerts ~1-2 min after the
  fault stops, burn-rate alerts ~5-6 min. Wait for recovery (or use `--full`)
  before running `scripts/slo-breach.sh` again.
- The consumed SLO error budget only returns as the time window rolls
  forward. Use `--full` for a clean budget.
- Set the time picker back to Last 15 minutes to show the healthy baseline.

Before a rehearsal or the meeting:

```bash
scripts/reset-demo.sh --full   # also resets both SLOs, redeploys dashboards from Git,
                               # waits (up to 6 min) for alerts to recover, then
                               # untracks any alert still active
```

Untracked alerts leave the Alerts page at once (they stay in alert history).
`--no-wait` untracks straight away; right after a fault an alert can then
fire once more and recover within ~5-6 min. `--wait-timeout MIN` changes the
wait. Alert
history, ML anomaly results and historical telemetry are kept.

After the meeting:

```bash
scripts/validate.sh            # optional record of the final state
terraform destroy
```

Check the `keep-until` tag value in `terraform/local.auto.tfvars` and destroy before
that date. See README.md, Teardown.

## Troubleshooting

| Symptom | Check |
|---|---|
| Scripts fail with "unreachable" | VPN/network, deployment running in the Elastic Cloud console, `terraform output kibana_url` |
| kubectl / terraform times out reaching the EKS API | The API only allows the IP you applied from. If your IP changed (new network, VPN), run `terraform apply` again, or set `eks_api_allowed_cidrs` in `terraform/local.auto.tfvars` |
| kubectl cannot reach `banking` | `aws eks update-kubeconfig --name $(terraform output -raw cluster_name) --region $(terraform output -raw aws_region) --profile $(terraform output -raw aws_profile)` |
| No traces for a service | Pod has an `opentelemetry-auto-instrumentation-*` init container; `kubectl -n opentelemetry-operator-system get pods`; load generator running |
| Trace sample Logs tab is empty, or a service is missing from it | `scripts/validate.sh --only 5` (shows `log->trace=no` per service). Check the service's log export setting in the table under scenario 2; the time picker must cover the trace |
| Bank UI spans missing (`web-banking-frontend` not in APM) | Browser dev tools > Network: `POST /v1/traces` should return 200. 403 means the request bypassed CloudFront; 503 means the web-banking pod has no `OTEL_EXPORTER_OTLP_ENDPOINT` (not auto-instrumented). `scripts/test-runbook.sh` check R7 posts a test span through the same path |
| Bank UI returns 403 from CloudFront | Your IP is not in `control_panel_allowed_cidrs` (the WAF ACL is shared with the control panel) |
| No new burn-rate alert | A previous alert is still active; wait for recovery or reset the SLO |
| AI Assistant not responding | Managed LLM connector in Stack Management > Connectors; user is `demo-sre` |
