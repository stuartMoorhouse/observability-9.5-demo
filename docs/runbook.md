# Demo Runbook: Elastic Observability 9.5 for Digital Banking

Persona: you are the on-call SRE for a retail bank's digital channels. The
customer-facing story is simple: customers make payment transfers in the web
banking app, and the bank needs to know, before customers complain, when
transfers slow down or fail, why, and who needs to act.

Application path: `web-banking` (Node.js) -> `transfer-service` (Java) ->
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
2. `scripts/reset-demo.sh` - baseline state, fx-rates removed.
3. `scripts/fault-inject.sh status` - every fault off, `APP_VERSION=1.4.2`.
4. Log in to Kibana in three browser profiles:
   - `elastic` (superuser, for setup only) - `terraform output -raw elastic_password`
   - `demo-sre` - `terraform output -raw demo_sre_password`
   - `demo-viewer` - `terraform output -raw demo_viewer_password`
5. Present as `demo-sre`. Set the time picker to **Last 15 minutes**,
   refresh every 10 s.
6. Open tabs: Observability > Applications > Service inventory, Service map,
   SLOs, Alerts, Discover (ES|QL), Dashboards.
7. If the SLO budget is depleted from rehearsals, reset it (SLOs > select the
   SLO > Actions > Reset).

Timing guide: the full flow is ~45 minutes. Scenarios 2 and 4 share one fault
window, so start `scripts/slo-breach.sh --keep-fault` early (see scenario 4).

---

## Scenario 1: Self-service Kubernetes onboarding (~7 min)

**Message:** a new team ships a service to the cluster and gets full
observability, SLO coverage, alerting and anomaly detection without opening a
ticket or touching Kibana.

| Step | Action | Talk track |
|---|---|---|
| 1 | Show Service inventory: 4 services, environment `banking-demo`. | "These are today's payment services. None of them contains an OpenTelemetry SDK; the OTel Operator injects instrumentation at pod start." |
| 2 | Show `charts/fx-rates/templates/deployment.yaml` (the annotation `instrumentation.opentelemetry.io/inject-python`). | "This annotation is the only observability configuration the fx-rates team adds. That is the platform contract." |
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

Pick one fault per run. Recommended order for a first meeting: `bad-version`
(best correlation story), then `slow-db` (best trace waterfall story).

| Fault | Command | Visible after |
|---|---|---|
| Latency on transfer-service | `scripts/fault-inject.sh latency on 1500` | alert ~2-5 min |
| Errors in fraud-check | `scripts/fault-inject.sh errors on 30` | error rate ~1 min, alert ~2-5 min |
| Slow DB in accounts-ledger | `scripts/fault-inject.sh slow-db on` | slow DB spans ~1 min |
| Bad release of transfer-service | `scripts/fault-inject.sh bad-version on` | new version ~1-2 min, correlations ~5 min |

Start the fault 5 minutes before you need it.

| Step | Action | Talk track |
|---|---|---|
| 1 | Observability > Alerts: the latency / error-rate alert for `transfer-service` (or `fraud-check`). Open the alert details. | "Customers' transfers are slowing down. We were told by the platform, not by the contact centre." |
| 2 | Service map (environment `banking-demo`): alert badge on the affected node; SLO and anomaly indicators on the service. Click the node > Service details. | "One view tells us which hop is unhealthy and whether it is burning the SLO." |
| 3 | Service overview: latency and failed transaction rate charts. Note the version comparison (bad-version: `2.0.0` appears next to `1.4.2`). | "A new version went out at the same time the regression started." |
| 4 | Transactions > `POST /transfer` > **Latency correlations** / **Failed transaction correlations**. | "Elastic compares slow or failed transactions with healthy ones and ranks the attributes that explain the difference. Here `service.version: 2.0.0` is at the top." |
| 5 | Pick a slow sample > **Trace waterfall**. For slow-db, expand the `accounts-ledger` span and the Postgres child span with `pg_sleep`. For errors, open the span error and the `LedgerContractMismatchException` (bad-version) or HTTP 500 exception (errors). | "End-to-end trace across Node, Java, .NET and Python, and the exact span where the time goes." |
| 6 | Still on the trace sample, open the **Logs** tab (next to Timeline and Metadata). Bad-version: the `ERROR Ledger contract mismatch ...` line from transfer-service. Errors: `Unhandled exception processing /score` from fraud-check. Slow-db: `WARN Slow ledger query ...` from accounts-ledger. Every service in the trace contributes lines (web-banking `transfer processed`, fraud-check `Scored transfer ...`, accounts-ledger `Posted debit ...`). | "These are the application logs for this one request, from all four services and languages. No SDK code in the apps, no log parsing: the EDOT agents write the trace id on every log record." |
| 7 | Click a log line > open its details > **trace.id** / "View trace" to go from log back to the trace. | "It works both ways: whoever starts from a log line gets the full request in one click." |
| 8 | Discover, ES|QL `FROM traces-*` (or a `traces-*` data view). Filter to a failing transfer (`service.name == "transfer-service" AND status.code == "Error"`), expand a row. The **Overview** tab shows the trace summary and a **Logs** section with the correlated logs; **Open in Discover** opens them as a log list (technical preview). | "The same correlation in Discover, for teams that live in logs and traces rather than the APM UI." |
| 9 | Discover > ES|QL. Run the queries below (the second one is all logs for the trace you just opened). | "And when the out-of-the-box views are not enough, every signal is queryable with one language." |

ES|QL examples (paste into Discover, mode ES|QL):

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

How log correlation works here: each EDOT SDK (Java, .NET, Node.js, Python)
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

Lead time: start the breach ~15 minutes before this scenario, ideally at the
start of scenario 2:

```bash
scripts/slo-breach.sh --keep-fault
```

It records the fault start (UTC), injects 3000 ms latency on
`transfer-service`, polls the SLO alerts index every 15 s for the burn-rate
rule from `terraform output burn_rate_rule_id`, and writes
`results/slo-breach-<timestamp>.json` with `fault_start`, `alert_detected`
and `detection_delay_seconds`. Typical delay: 5-10 minutes (depends on the
rule's short window and evaluation interval). Without `--keep-fault` the fault
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

- Active alerts recover on their own after the next healthy rule evaluations;
  burn-rate alerts take longer (short window must clear, typically 5-15 min).
  Wait for recovery before running `scripts/slo-breach.sh` again.
- The consumed SLO error budget only returns as the time window rolls
  forward. Use `--full` for a clean budget.
- Set the time picker back to Last 15 minutes to show the healthy baseline.

Before a rehearsal or the meeting:

```bash
scripts/reset-demo.sh --full   # also resets both SLOs, redeploys dashboards from Git,
                               # and waits (up to 15 min) until no alerts are active
```

`--no-wait` skips the alert wait; `--wait-timeout MIN` changes it. Alert
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
| No new burn-rate alert | A previous alert is still active; wait for recovery or reset the SLO |
| AI Assistant not responding | Managed LLM connector in Stack Management > Connectors; user is `demo-sre` |
