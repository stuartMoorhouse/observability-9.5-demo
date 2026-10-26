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

## How each scenario is structured

Every scenario follows Tell-Show-Tell:

1. **Context (off screen, ~1 min).** Stop sharing. Describe the operational
   problem the scenario addresses, what you are about to show, and the one
   thing worth watching for. People who know what to look for follow the
   screen; people who don't tend to conclude the product is complicated.
2. **Show (5 min or less).** One workflow, step by step. The "Say" column
   describes what is on screen. If you hear yourself say "and it also does
   this", you have drifted: those items are listed under "If asked" instead.
3. **What it means (off screen, ~1 min).** Stop sharing again. Say what the
   workflow changes for each team in the room, using only the lines for teams
   that are actually present. Mention the stated limits: they are part of an
   accurate picture, not a weakness to hide.

The "Off screen" line in each Context is the moment to press the control
panel button for the next fault, so you never wait on screen.

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
8. Note which teams are attending and pick the scenarios that are relevant to
   them. The "What it means" lines are grouped by team:

   | Team | Most relevant scenarios |
   |---|---|
   | On-call SREs | 2, 3a, 4 |
   | Platform engineering | 1, 5 |
   | Application development | 1, 2 |
   | Risk, security and compliance | 3b, 4, 5 |

Timing guide: each scenario takes ~7 minutes (1 + 5 + 1); the full flow is
~45 minutes. Scenarios 2 and 4 share one fault window, so start
`scripts/slo-breach.sh --keep-fault` early (see scenario 4).

Quick demo (~15 min): scenarios 1 and 2 only. Inject the scenario 2 fault
during the scenario 1 Context; by the time onboarding is done the alert and
correlations are ready.

Rule timings are tuned for demos (`terraform/modules/kibana-content/rules.tf`):
threshold rules look at the last 1 minute, the fastest burn-rate window is
5 min long / 1 min short, and every short window is 1 min. Alerts
fire and recover in minutes. These are not production settings.

---

## Opening the meeting (off screen, ~3 min)

- The situation: a retail bank's payment path, five services in four
  languages on Kubernetes, and an on-call team that needs to find out about
  slow or failing transfers before customers report them.
- The agenda: list the scenarios you picked, one sentence each, and ask
  whether one of them matters more or less than you assumed. Adjust the order.
- If useful, the control panel's Demo scenario tab shows the app path and how
  the telemetry reaches Elastic, before you switch to Kibana.

---

## Scenario 1: Self-service Kubernetes onboarding (~7 min)

### Context (off screen)

- **The problem:** in many platform teams, a new service gets monitoring only
  after someone requests it: dashboards, alert rules, an SLO. Until then it
  runs unobserved, and the setup work grows with every service.
- **What you'll see:** a new service, fx-rates, deployed with one Kubernetes
  annotation and no other observability setup. It then appears in traces, the
  service map, the SLO, alerting and anomaly detection.
- **Worth watching for:** nothing is configured in Kibana during this
  scenario.
- **Off screen:** if scenario 2 follows, start its fault now (control panel >
  Bad release **On**).

### Show

| Step | Action | Say |
|---|---|---|
| 1 | Service inventory: 4 services, environment `banking-demo`. | "These are today's payment services. None of them contains an OpenTelemetry SDK; the OTel Operator injects instrumentation when each pod starts." |
| 2 | Show `charts/fx-rates/templates/fx-rates.yaml` (the annotation `instrumentation.opentelemetry.io/inject-python`). | "This annotation is the only observability configuration in the fx-rates chart." |
| 3 | Control panel > **Onboard** (or `scripts/onboard-service.sh`). | "This does the `helm upgrade --install` that a CI/CD pipeline or GitOps tool would normally run, and times how long until the first traces arrive." |
| 4 | While it waits (pods ready ~30-60 s, first spans typically 1-3 min): Infrastructure > Kubernetes, filter namespace `banking`, show the new pod. | "The node and pod views pick up the new workload from the collector on each node; nothing to register." |
| 5 | Refresh Service inventory: `fx-rates` appears. Service map: a new `transfer-service -> fx-rates` edge. | "The dependency is drawn from traces, because transfer-service now calls fx-rates for cross-currency transfers." |
| 6 | SLOs: open the transfer latency SLO and find the `fx-rates` instance (may take ~5 min to appear). | "The SLO was defined once, grouped by service, so a new service gets its own instance." |

If asked: Stack Management > Rules (latency and error-rate rules are grouped
by `service.name`); Machine Learning > Anomaly Detection (the job covers every
service in the environment).

Fallback: if fx-rates traces are slow, check `scripts/generate-load.sh status`
and the pod init container (`kubectl -n banking get pod -l app.kubernetes.io/name=fx-rates -o jsonpath='{.items[0].spec.initContainers[*].name}'`).

### What it means (off screen)

- **On-call SREs:** a service launched last week arrives with the same
  traces, logs, SLO and alerts as one launched years ago, so an incident in
  either looks the same.
- **Platform engineering:** the contract with application teams is one
  annotation. The SLO, rules and anomaly job are defined once per environment
  and apply to services that don't exist yet.
- **Application development:** no SDK to add to the code or keep upgrading,
  and deployment stays their normal pipeline.
- **Limits:** auto-instrumentation covers the frameworks each language agent
  supports. Business-specific spans or attributes still need code.

---

## Scenario 2: Incident to root cause (~7 min)

### Context (off screen)

- **The problem:** when a payment path degrades, the first part of an
  incident usually goes on establishing where the problem is: which service,
  which change, which team. That often takes several people and tools before
  anyone looks at the actual error.
- **What you'll see:** a new release of transfer-service that makes about one
  transfer in seven fail. We'll go from the customer's screen to the alert,
  the failing version and the exception, with traces and logs from services
  in four languages.
- **Worth watching for:** every step uses data the platform already
  collected. There is no query to write and nothing to search for.
- **Off screen:** the fault must have run for 3-5 minutes (control panel:
  transfer-service on `2.0.0`). If it is not on yet:
  `scripts/fault-inject.sh bad-version on` (control panel > Bad release
  **On**). It rolls out `2.0.0` with a simulated ledger contract regression:
  every transfer is ~0.4 s slower and about 15% fail with HTTP 500.

### Show

| Step | Action | Say |
|---|---|---|
| 1 | Bank UI: send a few transfers. They are slower, and some end in "Transfer failed". | "This is what the customer sees. Each click is traced in the browser, so the trace starts here rather than at the first server." |
| 2 | Observability > Alerts: the error-rate alert for `transfer-service`. Open the alert details. | "The platform raised this; nobody had to report it." |
| 3 | Service map (environment `banking-demo`): alert badge on `transfer-service`; SLO and anomaly indicators on the service. Click the node > Service details. | "This shows which hop is unhealthy and whether it is using up the SLO." |
| 4 | Service overview: latency and failed transaction rate charts. Version `2.0.0` appears next to `1.4.2`. | "A new version went out at the same time as the regression started." |
| 5 | Transactions > `POST /transfer` > **Failed transaction correlations**. | "This compares failed transactions with successful ones and ranks the attributes that differ most. `service.version: 2.0.0` is at the top." |
| 6 | Pick a failed sample > **Trace waterfall**. Open the span error: `LedgerContractMismatchException` ("Ledger response missing field 'postingId' (contract v2)"). | "The exception from the new release, on the request that failed. The transfer stops before it reaches fraud-check or the ledger." |
| 7 | Still on the trace sample, open the **Logs** tab: the `ERROR Ledger contract mismatch ...` line from transfer-service and the `transfer failed` line from web-banking for the same request. | "The application logs for this one request. There is no logging code for this in the apps: the agents add the trace id to every log record." |

If asked:

- Log to trace: click a log line > open its details > **trace.id** / "View
  trace".
- The same view in Discover: ES|QL `FROM traces-*`, filter to
  `service.name == "transfer-service" AND status.code == "Error"`, expand a
  row. The **Overview** tab shows the trace summary and a **Logs** section;
  **Open in Discover** opens them as a log list (technical preview).
- Ad-hoc analysis: the first and third [ES|QL queries](#esql-queries)
  (failures and p95 by `service.version`, errors by version).
- Other failure types: [Appendix: other faults](#appendix-other-faults-for-scenario-2).

### What it means (off screen)

- **On-call SREs:** the alert leads to the evidence: the failing version, the
  exception and that request's logs. The first conversation with the
  application team can start from specifics.
- **Application development:** the correlation ranks version `2.0.0` first,
  so the rollback decision rests on data rather than on who argues best.
- **Platform engineering:** this worked across Node.js, Java, .NET and Python
  without any of those teams adding tracing code.
- **Limits:** correlations need enough failed transactions to compare, here
  3-5 minutes of traffic. With very low traffic the ranking is less clear.

Leave the fault on for scenario 3; turn it off afterwards with
`scripts/fault-inject.sh bad-version off`.

---

## Scenario 3a: AI-assisted triage (~6 min)

### Context (off screen)

- **The problem:** most incidents need the same sequence of triage steps, and
  less experienced on-call engineers take longer to work through them.
- **What you'll see:** the incident from scenario 2 investigated by an AI
  agent, which shows each tool call and the data it used.
- **Worth watching for:** whether its conclusion matches the one we reached
  by hand, and whether you can see the evidence behind it.
- **Off screen:** if scenario 4 follows, start `scripts/slo-breach.sh
  --keep-fault` now (it needs ~5 minutes).

### Show

| Step | Action | Say |
|---|---|---|
| 1 | As `demo-sre`, open the alert from scenario 2 and start the **AI Assistant** from the alert ("Help me understand this alert"), or open **Agent Builder > Agents** and chat with the observability agent. | "The model is the Elastic Managed LLM that comes with this deployment, so no third-party API key is configured." |
| 2 | Prompt: "Investigate the alerts on transfer-service in banking-demo over the last 30 minutes. Find the root cause and suggest next steps." The agent reads alerts, SLOs, service dependencies, correlations, traces and logs. | "It follows the same steps we took by hand, and each tool call is listed so the result can be checked." |
| 3 | Follow up: "Write an ES|QL query that shows the error rate by service.version for transfer-service." Run it in Discover. | "A query the SRE can verify and keep." |

### What it means (off screen)

- **On-call SREs:** a first pass at the investigation, with the queries it
  ran, to check and build on rather than start from nothing.
- **Risk, security and compliance:** the model is the Elastic Managed LLM of
  this deployment. Where data is processed is documented per region for the
  Elastic Managed LLM, and is worth confirming for your region.
- **Limits:** AI answers can be wrong or incomplete. The visible tool calls
  are there so a person verifies the conclusion before acting on it.

---

## Scenario 3b: AI access control (~4 min)

### Context (off screen)

- **The problem:** many organisations adopt AI features gradually, team by
  team, and need the platform to work fully for people who don't have AI
  access.
- **What you'll see:** the same incident as a user without AI privileges,
  and the role definitions that control it.
- **Worth watching for:** what is still available without AI.

### Show

| Step | Action | Say |
|---|---|---|
| 1 | Switch to the `demo-viewer` browser profile. Show the same alert, service map, correlations, trace waterfall and logs. There is no AI Assistant button and Agent Builder is not in the navigation. | "Everything used to find the root cause in scenario 2 is available without AI." |
| 2 | As `elastic`: Stack Management > Roles > `demo-viewer` (Observability read, no AI Assistant or Agent Builder privileges) compared with `demo-sre`. | "AI access is a role privilege like any other." |
| 3 | Show the role definitions in `terraform/modules/kibana-content/security.tf`. | "Both roles are defined in Terraform, so a change to AI access goes through code review." |

### What it means (off screen)

- **Risk, security and compliance:** AI access can follow the existing
  approval process, by team or by space, or be off entirely, and changes to
  it have a review history.
- **On-call SREs:** the core diagnosis workflow does not depend on AI being
  enabled or available.

---

## Scenario 4: SLO burn-rate alerting (~7 min, plus lead time)

### Context (off screen)

- **The problem:** threshold alerts on latency or error rate also fire on
  short spikes that customers barely notice, and frequent pages teach people
  to ignore them. SLO-based alerting pages on how fast the error budget is
  being used up instead.
- **What you'll see:** a latency SLO for transfers, a sustained breach, and
  the burn-rate alert it raises, with the detection time measured by a
  script.
- **Worth watching for:** the measured time from the start of the fault to
  the alert.
- **Off screen:** `scripts/slo-breach.sh --keep-fault` must have started ~5
  minutes ago (started during scenario 3a).

What the script does: it records the fault start (UTC), injects 3000 ms
latency on `transfer-service`, polls the SLO alerts index every 15 s for the
burn-rate rule from `terraform output burn_rate_rule_id`, and writes
`results/slo-breach-<timestamp>.json` with `fault_start`, `alert_detected`
and `detection_delay_seconds`. Typical delay: ~4 minutes (5 min / 1 min
fast-burn window, SLO transform delay, 1 min rule interval). Without
`--keep-fault` the fault is turned off when the script exits.

### Show

| Step | Action | Say |
|---|---|---|
| 1 | Observability > SLOs: the transfer latency SLO, grouped by `service.name`. Show the target, time window and remaining error budget for `transfer-service`. | "The objective is in customer terms: 99% of transactions complete within 500 ms, over a rolling 7 days." |
| 2 | Open the SLO: SLI chart and error budget burn-down. Show the linked burn-rate rule (several windows, fast and slow burn). | "A page goes out when the budget is being used fast enough to run out, not every time one request is slow." |
| 3 | Alerts: the burn-rate alert. Open it: burn rate, windows, reason. | "This is the alert that would page the on-call engineer." |
| 4 | Show the email notification, and Stack Management > Connectors > email connector > execution log: success. | "Sent through the Elastic Cloud email service. The same rule can call PagerDuty, ServiceNow or a webhook." |
| 5 | Show `results/slo-breach-<timestamp>.json`: `detection_delay_seconds`. | "This run took this many seconds from fault to alert, measured rather than estimated." |

If asked: from the SLO details, open the underlying events (APM service page
for `transfer-service` filtered to the SLO window, or **View in Discover**).

### What it means (off screen)

- **On-call SREs:** fewer pages, and the ones that arrive mean the budget is
  actually at risk.
- **Service owners:** each service, including new ones, has an objective in
  customer terms and a visible budget to plan releases against.
- **Risk and compliance:** detection time is something you can measure and
  report, as this run did.
- **Limits:** the rule windows here are shortened for the demo. Production
  windows are longer, so detection takes longer; choosing them is a trade-off
  between speed and false alarms.

End: `scripts/fault-inject.sh latency off`.

---

## Scenario 5: Observability as code (~7 min)

### Context (off screen)

- **The problem:** dashboards and alert rules created by hand drift between
  environments, and nobody can say who changed what, or why.
- **What you'll see:** a dashboard changed in Git and deployed with
  Terraform, and a dashboard built in the UI exported back to Git.
- **Worth watching for:** the UI and Git stay usable side by side.

### Show

| Step | Action | Say |
|---|---|---|
| 1 | Show `dashboards/` in the repo and the Terraform resource that deploys it through the Kibana Dashboards API on `terraform apply` (re-runs when a file changes). | "This JSON is the dashboard. It is reviewed in a pull request like any other change." |
| 2 | Kibana > Dashboards: open the banking dashboard. | |
| 3 | Edit a file in `dashboards/` (for example change a panel title), then `git diff`, `git commit`, `terraform apply` (only the dashboard resource changes; ~30 s). Refresh Kibana. | "Commit, apply, and it is live. The same flow works in every environment." |
| 4 | In Kibana, create or edit a dashboard by hand (add a panel), save it. | "Teams can still build in the UI." |
| 5 | `scripts/export-dashboard.sh "<dashboard title>"` writes `dashboards/<slug>.json`, normalised (server metadata stripped, keys sorted) so diffs are clean. Show `git diff --stat`. | "And bring it back into Git with one command, ready for review." |

If asked: SLOs, burn-rate and threshold rules, the email connector, the ML
job, roles and users are Terraform resources too (`elasticstack` provider).

Revert the demo edit afterwards (`git checkout -- dashboards/` and
`terraform apply`) if you do not want to keep it.

### What it means (off screen)

- **Platform engineering:** Kibana content is deployed the same way as the
  infrastructure, with review and history, and is the same in every
  environment.
- **Application development:** teams can still prototype in the UI and bring
  the result into Git with one command.
- **Risk and compliance:** changes to alerting, SLOs and access roles have a
  review trail in Git.

---

## Closing the meeting (off screen, ~3 min)

- One sentence per team present, drawn from the "What it means" lines of the
  scenarios you showed. Don't repeat every scenario.
- Ask which part they would want to see with their own services, and what
  would have to be true for that to be worth trying.

---

## Appendix: other faults for scenario 2

Alternatives to the bad release, or a second incident if there is time and
interest. Each needs its own short Context and recap.

| Fault | Command | Visible after |
|---|---|---|
| Bad release of transfer-service (scenario 2) | `scripts/fault-inject.sh bad-version on` | new version ~1-2 min, correlations ~3-5 min |
| [Slow database in accounts-ledger](#slow-database-in-accounts-ledger) | `scripts/fault-inject.sh slow-db on` | slow DB spans and WARN logs ~1 min |
| [Latency on transfer-service](#latency-on-transfer-service) | `scripts/fault-inject.sh latency on 1500` | alert ~1-2 min |
| [Errors in fraud-check](#errors-in-fraud-check) | `scripts/fault-inject.sh errors on 30` | error rate ~1 min, alert ~1-2 min |

To open the trace of your own transfer: APM > service `web-banking-frontend` >
transaction `Submit transfer` > latest sample. The browser span is the root,
above `web-banking`.

### Slow database in accounts-ledger

Context: a slowdown with no errors, where several services alert and only one
is the cause. Start: `scripts/fault-inject.sh slow-db on` (control panel >
Slow DB **On**). accounts-ledger adds `pg_sleep(0.8)` to balance lookups and
a slow duplicate-reference scan to every debit and credit: balances take
~0.8 s longer and transfers ~1.6 s longer. Nothing fails.

| Step | Action | Say |
|---|---|---|
| 1 | Bank UI: refresh the balance and send a transfer. Both succeed, but are noticeably slow. | "Nothing is broken, it is just slow. Customers often notice this kind of problem before monitoring does." |
| 2 | Observability > Alerts: the latency alert for `accounts-ledger`, and for `transfer-service` and `web-banking`, which wait on it. | "Three services alerting, one cause. Which one?" |
| 3 | Service map: alert badges along the chain. `accounts-ledger` is the deepest unhealthy service, next to its Postgres dependency. Click it > Service details. | "The map shows where the slowness starts." |
| 4 | Pick a slow sample > **Trace waterfall** (or your transfer from step 1). Expand the `accounts-ledger` span and its Postgres child span: the statement contains `pg_sleep`. | "The trace crosses Node.js, Java, .NET and Python, down to the query where the time goes." |
| 5 | Open the **Logs** tab: `WARN Slow ledger query: ... took N ms (threshold 500 ms)` from accounts-ledger, alongside the lines from every other service in the trace (web-banking `transfer processed`, fraud-check `Scored transfer ...`, accounts-ledger `Posted debit ...`). | "The application logs for this one request, from all four services." |
| 6 | Discover > ES|QL: the second and fourth [ES|QL queries](#esql-queries) (all logs for this trace, pod CPU). | "Pod CPU is flat: the database is waiting, not short of resources. More nodes would not fix it." |

Recap: for on-call SREs, the trace separates the services that are slow from
the one causing it; for application teams, the evidence is the exact query.

### Latency on transfer-service

Context: a slowdown inside one service, where the services it calls are
healthy. Start: `scripts/fault-inject.sh latency on 1500` (control panel >
Latency **On**). transfer-service waits 1500 ms on every transfer before
doing any work. Balance checks do not go through transfer-service and are
unaffected.

| Step | Action | Say |
|---|---|---|
| 1 | Bank UI: send a transfer (1.5 s or more), then refresh the balance (fast). | "Only transfers are slow, so the problem is on the transfer path." |
| 2 | Observability > Alerts: the latency alert for `transfer-service`, and for `web-banking`, which waits on it. | "The platform raised this before anyone reported it." |
| 3 | Service map: alert badge on `transfer-service`; its dependencies `fraud-check` and `accounts-ledger` are healthy. | "The services it calls are fine, so the time is spent inside transfer-service." |
| 4 | Pick a slow sample > **Trace waterfall**. The `POST /transfer` span in transfer-service is ~1.5 s long, but its calls to fraud-check and accounts-ledger take their normal time; the gap before the first child call is the delay. | "The trace rules out the downstream services." |
| 5 | Discover > ES|QL: `FROM logs-*.otel-* \| WHERE service.name == "transfer-service" AND body.text LIKE "Fault config changed*"`. The `Fault config changed: LATENCY_MS=1500` line marks the moment it started. | "In a real incident, this is the config change or deployment to look for at the start of the regression." |

Recap: for on-call SREs, healthy dependencies narrow the search to one
service; the log line ties the start of the regression to a change.

### Errors in fraud-check

Context: intermittent failures that start in one service and surface in
several. Start: `scripts/fault-inject.sh errors on 30` (control panel >
Errors **On**). 30% of fraud-check calls hang for 200-600 ms and then fail
with HTTP 500 (`FraudModelTimeoutException`). The transfer fails with them.

| Step | Action | Say |
|---|---|---|
| 1 | Bank UI: send a few transfers. About one in three ends in "Transfer failed" (HTTP 500). | "Some customers can't pay. Which ones, and why?" |
| 2 | Observability > Alerts: the error-rate alerts for `fraud-check`, `transfer-service` and `web-banking`. | "Three services alerting; the errors start at one of them." |
| 3 | Service map: `fraud-check` is the deepest service with an alert badge. Click it > Service details. | "The errors start at fraud-check and travel up the call chain." |
| 4 | fraud-check > **Errors**: the `FraudModelTimeoutException` group, with its occurrences over time. | "Errors are grouped by type, with the stack trace and when they were first and last seen." |
| 5 | Open a failed sample > **Trace waterfall** (or your failed transfer from step 1). The error on the fraud-check span becomes an HTTP 500 in transfer-service, web-banking and the browser. | "One trace shows how far the failure reaches, from the fraud model to the customer's screen." |
| 6 | Open the **Logs** tab: `Unhandled exception processing /score` from fraud-check, and the failure as it surfaced in web-banking (`transfer failed`). | "The logs for this one request, from every service, without searching." |
| 7 | Discover > ES|QL: the third [ES|QL query](#esql-queries) (errors by service and version). | "Every signal can be queried with the same language." |

Recap: for on-call SREs, the origin of the errors is clear even when several
services alert; for application teams, the error group gives the stack trace
and frequency.

### ES|QL queries

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
| A service is missing its init container after nodes were replaced | The pod started before the OTel Operator was ready. `kubectl -n banking rollout restart deployment/<service>`, then `scripts/validate.sh --only 3` |
| Trace sample Logs tab is empty, or a service is missing from it | `scripts/validate.sh --only 5` (shows `log->trace=no` per service). Check the service's log export setting in [How log correlation works](#how-log-correlation-works); the time picker must cover the trace |
| Bank UI spans missing (`web-banking-frontend` not in APM) | Browser dev tools > Network: `POST /v1/traces` should return 200. 403 means the request bypassed CloudFront; 503 means the web-banking pod has no `OTEL_EXPORTER_OTLP_ENDPOINT` (not auto-instrumented). `scripts/test-runbook.sh` check R7 posts a test span through the same path |
| Bank UI returns 403 from CloudFront | Your IP is not in `control_panel_allowed_cidrs` (the WAF ACL is shared with the control panel) |
| No new burn-rate alert | A previous alert is still active; wait for recovery or reset the SLO |
| AI Assistant not responding | Managed LLM connector in Stack Management > Connectors; user is `demo-sre` |
