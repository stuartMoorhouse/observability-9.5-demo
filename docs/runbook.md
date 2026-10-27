# Demo Runbook: Elastic Observability 9.5 for Digital Banking

This runbook walks through five scenarios on a demo payments application for a
retail bank. Customers make payment transfers in the web banking app; the
bank's on-call SRE team needs to know when transfers slow down or fail, why,
and who needs to act, before customers report it.

Application path: the bank's browser UI (`web-banking-frontend`, OpenTelemetry
browser RUM) -> `web-banking` (Node.js) -> `transfer-service` (Java) ->
`fraud-check` (.NET) and `accounts-ledger` (Python, Postgres). `fx-rates`
(Python) is added in scenario 1. Environment: `banking-demo`.

All scripts run from the repo root and read endpoints and credentials from
`terraform output` in `terraform/`. Run the `terraform` commands below from
`terraform/` (or add `-chdir=terraform`).

The reset (`scripts/reset-demo.sh`, or the control panel's **Reset demo**)
leaves the demo ready for every scenario: fx-rates removed, other faults off,
and a faulty release of transfer-service (`2.0.0`) rolling out. That release
is the incident scenarios 2 to 4 investigate, each from a different angle.

The demo control panel (`terraform output -raw control_panel_url`) has a
button for every fault, onboarding and load command in this runbook, a live
view of their state, and a plain reset. `reset-demo.sh --full`,
`detection-delay.sh` and `slo-breach.sh` need the terminal. See the README, "Demo control panel".

## How the scenarios are organised

Each scenario is self-contained and takes about 7 minutes:

- **Overview:** the operational problem the scenario addresses, what it
  demonstrates, and what to look for.
- **Before you begin:** the state the environment must be in, for example a
  fault that needs a few minutes to take effect.
- **Steps:** one workflow, about 5 minutes. *What you see* describes the
  result of each step.
- **Explore further:** optional related features, kept out of the main path.
- **What this shows:** the outcome for each role involved, and the
  limitations that apply.

## Which scenarios to run

| Scenario | Most relevant to |
|---|---|
| [1. Self-service Kubernetes onboarding](#scenario-1-self-service-kubernetes-onboarding) | Platform engineers, application developers |
| [2. Incident to root cause](#scenario-2-incident-to-root-cause) | On-call SREs, application developers |
| [3a. AI-assisted triage](#scenario-3a-ai-assisted-triage) | On-call SREs |
| [3b. AI access control](#scenario-3b-ai-access-control) | Risk, security and compliance |
| [4. SLO burn-rate alerting](#scenario-4-slo-burn-rate-alerting) | On-call SREs, service owners, risk and compliance |
| [5. Observability as code](#scenario-5-observability-as-code) | Platform engineers, risk and compliance |

Suggested order: 1, 2, 3a, 3b, 4, 5 (~45 minutes). Every scenario is ready
about 5-6 minutes after a reset; scenario 1 fills that time.

Short version (~15 minutes): scenarios 1 and 2.

Alert rule timings are shortened for the demo
(`terraform/modules/kibana-content/rules.tf`): threshold rules look at the
last 1 minute, the fastest burn-rate window is 5 min long / 1 min short, and
every short window is 1 min. Alerts fire and recover in minutes. These are
not production settings.

## Prepare the environment

About an hour before running the scenarios:

1. `scripts/validate.sh` - all read-only checks PASS (criteria 6-9 and 14
   SKIP; 10 SKIPs without email recipients).
   For a full rehearsal, run `scripts/test-runbook.sh` instead (~25-35 min):
   it resets, drives scenarios 1, 2 and 3b and the scenario 2 faults through
   the APIs, raises a latency SLO breach, checks the runbook's ES|QL queries,
   log correlation and the bank UI, and resets again. It lists the steps to
   check by eye at the end, including scenario 3a and the scenario 4
   availability alert.
2. `scripts/reset-demo.sh --full` - resets the SLOs, deletes the history of
   earlier runs (alerts, cases, AI triage workflow runs and conversations),
   removes fx-rates, turns the other faults off and then turns on the bad
   release for scenarios 2-4. It takes ~2-3 min, or up to ~8 min when a fault
   ran in the last few minutes (it waits for alerts to recover first, so the
   bad release raises a new alert against a full error budget).
3. `scripts/fault-inject.sh status` - `APP_VERSION=2.0.0 BAD_RELEASE=true`,
   every other fault off.
4. Log in to Kibana in three browser profiles (separate profiles keep the
   sessions apart):
   - `elastic` (superuser, for setup only) - `terraform output -raw elastic_password`
   - `demo-sre` - `terraform output -raw demo_sre_password`
   - `demo-viewer` - `terraform output -raw demo_viewer_password`
5. Use the `demo-sre` profile unless a step says otherwise. Set the time
   picker to **Last 15 minutes**, refresh every 10 s.
6. Open tabs: the bank UI (`terraform output -raw web_banking_url`),
   Observability > Applications > Service inventory, Service map, SLOs,
   Alerts, Discover (ES|QL), Dashboards. Send one transfer in the bank UI so
   `web-banking-frontend` is on the service map.
7. Optional: start `scripts/detection-delay.sh` in a second terminal. It
   waits for the burn-rate alert the bad release raises (~5-6 min) and records
   the detection delay shown in scenario 4.

---

## Scenario 1: Self-service Kubernetes onboarding

### Overview

In many platform teams, a new service gets monitoring only after someone
requests it: dashboards, alert rules, an SLO. Until then it runs unobserved,
and the setup work grows with every service. This scenario deploys a new
service, fx-rates, with one Kubernetes annotation and no other observability
setup, and follows it into traces, the service map, the SLO, alerting and
anomaly detection.

**What to look for:** nothing is configured in Kibana during this scenario.

### Before you begin

Ready after the reset, which removes fx-rates. transfer-service may already
show an alert in the inventory: that is the faulty release scenario 2
investigates.

### Steps

| Step | Action | What you see |
|---|---|---|
| 1 | Open Service inventory. | The four backend services in environment `banking-demo`, plus `web-banking-frontend` (the browser, instrumented with the OpenTelemetry web SDK). None of the backend services contains an OpenTelemetry SDK; the OTel Operator injects instrumentation when each pod starts. |
| 2 | Open `charts/fx-rates/templates/fx-rates.yaml`. | The annotation `instrumentation.opentelemetry.io/inject-python`, the only instrumentation the chart asks for. The other OpenTelemetry settings are environment variables: service name, environment and version, and log export. |
| 3 | `scripts/onboard-service.sh` (or control panel > **Onboard**). | The script runs the `helm upgrade --install` that a CI/CD pipeline or GitOps tool would normally run, and reports how long the first traces take to arrive. The panel's Onboard applies the same rendered chart. |
| 4 | While it runs (pods ready ~30-60 s, first spans typically 1-3 min): Infrastructure > Kubernetes, filter namespace `banking`. | The new pod, picked up by the collector on each node with nothing to register. |
| 5 | Refresh Service inventory, then open Service map. | `fx-rates` in the inventory, and a new `transfer-service -> fx-rates` edge drawn from traces: transfer-service calls fx-rates for cross-currency transfers. |
| 6 | SLOs: open **Banking transaction latency (500 ms)**. | An `fx-rates` instance (may take ~5 min to appear). The SLO was defined once, grouped by service, so a new service gets its own instance. |

If fx-rates traces are slow to appear, check `scripts/generate-load.sh status`
and the pod init container (`kubectl -n banking get pod -l app.kubernetes.io/name=fx-rates -o jsonpath='{.items[0].spec.initContainers[*].name}'`).

### Explore further

- Stack Management > Rules: the latency and error-rate rules are grouped by
  `service.name`, so they cover fx-rates too.
- Machine Learning > Anomaly Detection: the job covers every service in the
  environment.

### What this shows

- **On-call SREs:** a service launched last week has the same traces, logs,
  SLO and alerts as one launched years ago.
- **Platform engineers:** the contract with application teams is one
  annotation plus the standard OpenTelemetry environment variables. The SLO, rules and anomaly job are defined once per environment
  and apply to services that don't exist yet.
- **Application developers:** no SDK to add or keep upgrading, and deployment
  stays their normal pipeline.

### Limitations

Auto-instrumentation covers the frameworks each language agent supports.
Business-specific spans or attributes still need code.

---

## Scenario 2: Incident to root cause

### Overview

When a payment path degrades, the first part of an incident usually goes on
establishing where the problem is: which service, which change, which team.
This scenario follows a faulty release of transfer-service from the
customer's screen to the failing version and the exception, using traces and
logs from services written in four languages.

**What to look for:** every step uses data the platform already collected; no
queries are written.

### Before you begin

Ready 3-5 minutes after the reset, which deploys transfer-service `2.0.0`
with a simulated ledger contract regression: every transfer is ~0.4 s slower
and about 25% fail with HTTP 500. The control panel shows transfer-service on
`2.0.0` once it is active. To start it without a reset: control panel > Bad
release **On**, or `scripts/fault-inject.sh bad-version on`.

### Steps

| Step | Action | What you see |
|---|---|---|
| 1 | In the bank UI, send a few transfers. | Transfers are slower and some end in "Transfer failed". Each click is traced in the browser, so the trace starts there rather than at the first server. |
| 2 | Observability > Alerts: open the error-rate alert for `transfer-service`. | The platform raised the alert; nobody had to report the problem. |
| 3 | Service map (environment `banking-demo`): click `transfer-service` > Service details. | An alert badge on `transfer-service`, with SLO and anomaly indicators showing whether the problem is using up the SLO. |
| 4 | Service overview: latency and failed transaction rate charts. | Version `2.0.0` appears next to `1.4.2` at the time the regression started. |
| 5 | Transactions > `POST /transfer` > **Failed transaction correlations**. | `service.version: 2.0.0` ranks first among the attributes that distinguish failed transactions from successful ones. |
| 6 | **Trace samples**: filter with `event.outcome: "failure"` in the search bar, then open the **Timeline** tab and the error on the `POST /transfer` transaction. | `LedgerContractMismatchException` ("Ledger response missing field 'postingId' (contract v2)") on the failed request. The transfer stops before it reaches fraud-check or the ledger, so there are no child spans below it. |
| 7 | On the same trace sample, open the **Logs** tab. | The `ERROR Ledger contract mismatch ...` line from transfer-service and the `transfer failed` line from web-banking for this request. The applications contain no code for this: the agents add the trace id to every log record. |

To open the trace of your own transfer from step 1: APM > service
`web-banking-frontend` > transaction `Submit transfer` > latest sample. The
browser span is the root, above `web-banking`.

### Explore further

- Log to trace: click a log line > open its details > **trace.id** / "View
  trace".
- The same correlation in Discover, step by step with ES|QL:
  [Trace-log correlation in Discover](#trace-log-correlation-in-discover).
  Without queries: in Discover, expand a `traces-*` row; the **Overview** tab
  shows the trace summary and a **Logs** section, and **Open in Discover**
  opens them as a log list (technical preview).
- Ad-hoc analysis: the first and third [ES|QL queries](#esql-queries)
  (failures and p95 by `service.version`, errors by version).
- Other failure types: [Appendix: other faults](#appendix-other-faults-for-scenario-2).

### What this shows

- **On-call SREs:** the alert leads directly to the failing version, the
  exception and that request's logs, so the first conversation with the
  application team starts from specifics.
- **Application developers:** the rollback decision rests on the correlation
  ranking rather than judgement.
- **Platform engineers:** tracing worked across Node.js, Java, .NET and
  Python with no tracing code in the applications.

### Limitations

Correlations need enough failed transactions to compare, typically 3-5
minutes of traffic. With very low traffic the ranking is less clear.

The bad release stays on for scenarios 3a, 3b and 4.

---

## Scenario 3a: AI-assisted triage

### Overview

Most incidents need the same sequence of triage steps, and less experienced
on-call engineers take longer to work through them. In this scenario the
first pass runs automatically: when the error-rate alert from scenario 2
fires, an Elastic Workflow hands it to an AI agent, which investigates and
records its findings in a case before anyone opens the alert.

The workflow is **Banking alert triage**, defined in Git
(`terraform/modules/kibana-content/workflows/alert-triage.yaml`). The
error-rate rule runs it once for each new alert, so once per service that
starts failing. It first checks for an open triage case for the service: if
one exists (the error rate dipped under the threshold and the alert fired
again), it adds the new alert to that case and stops. Otherwise:

1. **investigate** - runs the `banking-triage` Agent Builder agent on the
   alert. The agent follows the same path as scenario 2 (alerts, service
   topology, correlations, traces, logs) and returns a structured result:
   summary, root cause, confidence, evidence, next steps and an ES|QL query.
2. **create_case** - opens an Observability case with that result and a link
   to the agent's conversation.
3. **attach_alert** - attaches the alert to the case.

**What to look for:** whether the agent's conclusion matches the one reached
by hand in scenario 2, and whether each finding can be traced to the tool
call that produced it.

### Before you begin

- The bad release from the reset must still be running.
- The cases appear 3-4 minutes after the reset: the error-rate alerts fire
  about 2 minutes after it (rollout plus the 1 minute rule window), and the
  agent then takes about 2 minutes per alert. They are ready by the time scenario 1 ends.
- Run `scripts/reset-demo.sh --full` before this scenario. It deletes the
  cases, workflow runs and conversations from earlier runs. After a plain
  reset the earlier cases are still open, so new alerts are added to them and
  no new investigation runs.

### Steps

| Step | Action | What you see |
|---|---|---|
| 1 | As `demo-sre`, open **Workflows** > **Banking alert triage** > **Executions** and open the latest run. | One run per alerting service (`transfer-service` and `web-banking`), each with its trigger (the alert), its steps, their inputs and outputs, and their duration. A later run for the same service adds its alert to the existing case and skips the investigation. |
| 2 | Observability > **Cases**: open the `AI triage: transfer-service - ...` case. | The agent's summary, root cause and confidence, the evidence list, next steps and an ES\|QL query, with the alert attached. The result was produced by the workflow; nobody asked for it. |
| 3 | Follow the **Agent conversation** link in the case. The error-rate rule is owned by `demo-sre`, so the workflow, and the conversation, run as that user. | The agent's conversation in Agent Builder: every tool call (alerts, topology, correlations, traces, logs, ES\|QL) with its input and result, so each finding can be checked against the data. |
| 4 | Copy the case's ES\|QL query and run it in Discover. | A query that can be verified and kept, for example the error rate by `service.version`. |
| 5 | In the conversation, ask a follow-up: "Which deployment introduced this version, and when?" | The agent continues from the same context. The automated first pass becomes the start of an interactive investigation. |

### Explore further

- Open the `web-banking` case. The agent should identify `web-banking` as
  failing because it calls `transfer-service`, not as the cause.
- The **AI Assistant** button on the alert ("Help me understand this alert")
  gives the same kind of analysis on demand, without the workflow.
- The workflow and the agent (`terraform/modules/kibana-content/triage.tf`)
  and the action on the error-rate rule (`rules.tf`) are all Terraform
  resources, reviewed and deployed like
  the rest of the configuration (scenario 5).

### What this shows

- **On-call SREs:** by the time the alert is opened, a first investigation is
  already in a case, with the queries behind it, to check and build on.
- **Platform engineers:** the triage is a versioned workflow, not a manual
  procedure, and the same pattern can add notification, ticketing or
  remediation steps.
- **Risk, security and compliance:** the model is the Elastic Managed LLM of
  this deployment, and no third-party API key is configured. Where data is
  processed is documented per region for the Elastic Managed LLM and should
  be confirmed for the region in use. Each run is recorded in the workflow's
  execution history.

### Limitations

AI answers can be wrong or incomplete, and two runs on the same alert can
word their conclusions differently. The case says so at the top, and links to
the tool calls so that a person verifies the conclusion before acting on it.

---

## Scenario 3b: AI access control

### Overview

Many organisations adopt AI features gradually, team by team, and need the
platform to work fully for people without AI access. This scenario repeats
the scenario 2 investigation as a user without AI privileges, then shows the
role definitions that control access.

**What to look for:** what is still available without AI.

### Before you begin

The scenario 2 fault should still be running, so that the same alert and
traces are available.

### Steps

| Step | Action | What you see |
|---|---|---|
| 1 | Switch to the `demo-viewer` browser profile. Open the same alert, service map, correlations, trace timeline and logs, then the AI triage case from scenario 3a and its **Agent conversation** link. | Everything used in scenario 2 works. There is no AI Assistant button, and Agent Builder is not in the navigation. The case can be read, but the conversation does not open: it belongs to `demo-sre`. |
| 2 | In the `elastic` profile: Stack Management > Roles > `demo-viewer`, then `demo-sre`. | `demo-viewer` has Observability read and no AI Assistant or Agent Builder privileges; `demo-sre` has both. AI access is an ordinary role privilege. |
| 3 | Open `terraform/modules/kibana-content/security.tf`. | Both roles are defined in Terraform, so a change to AI access goes through code review. |

### What this shows

- **Risk, security and compliance:** AI access can follow an existing
  approval process, by team or by space, or be off entirely, and changes to
  it have a review history.
- **On-call SREs:** the core diagnosis workflow does not depend on AI being
  enabled or available.

---

## Scenario 4: SLO burn-rate alerting

### Overview

Scenarios 2 and 3 looked at the faulty release from the engineering side:
which service, which version, which line. This scenario looks at the same
incident through a service level objective, the way a service owner or
incident manager would: how much of the agreed reliability has been used up,
and how quickly. Threshold alerts also fire on short spikes that customers
barely notice; SLO-based alerting pages on how fast the error budget is being
used up instead.

**What to look for:** the same release, now expressed as error budget, and
the measured time from the release to the alert.

### Before you begin

Ready about 5-6 minutes after `scripts/reset-demo.sh --full`: the reset
restores the full error budget, clears earlier alerts and then starts the bad
release, so the burn-rate alert it raises is new.

Run `scripts/detection-delay.sh` (or start it during preparation). It reads
the bad release start time from the transfer-service Deployment, waits until
the availability burn-rate rule pages for `transfer-service` (action group
fast burn or high), and writes `results/detection-delay-<timestamp>.json`
with `fault_start`, `paging_alert_at` and `detection_delay_seconds`. Typical
delay: ~5 minutes (rollout, SLO transform delay, burn-rate windows, 1 min
rule interval). A measured run: 282 s.

### Steps

| Step | Action | What you see |
|---|---|---|
| 1 | Observability > SLOs: **Banking transaction availability**, grouped by `service.name`. | The `transfer-service` instance is using its error budget fastest: the same release from scenario 2. `web-banking`, which passes the failed transfers on to the browser, uses budget more slowly, because most of its requests are balance checks. The objective is in customer terms: 99% of transactions succeed over a rolling 7 days. |
| 2 | Open the latency SLO for `transfer-service`. | Still healthy: the release made transfers ~0.4 s slower, but within the 500 ms objective. The SLOs show which promise is being broken. |
| 3 | Open the availability SLO's `transfer-service` instance, then its linked burn-rate rule. | The SLI chart, the error budget burn-down, and a rule with several windows (fast and slow burn): it alerts when the budget is being used fast enough to run out, not when a single request fails. |
| 4 | Alerts: open the availability burn-rate alert for `transfer-service`. | The severity rises as the windows fill: Medium or High first, then **Critical** about 8 minutes after the reset, when the 5 min and 1 min burn rates (around 20) are both above 14.4, the fast-burn threshold. High and Critical are the severities that page the on-call engineer. The lower severities come first because, right after the SLO reset, the longer windows hold only a few minutes of data. |
| 5 | If `alert_email_recipients` is set: open the email notification, then Stack Management > Connectors > email connector > execution log. | A successful delivery through the Elastic Cloud email service. The same rule can call PagerDuty, ServiceNow or a webhook. With no recipients, the rules have no email action. |
| 6 | Open `results/detection-delay-<timestamp>.json` (or the script's output). | `detection_delay_seconds`: the measured time from turning on the release to the paging alert in this run. |

### Explore further

- From the SLO details, open the underlying events: the APM service page for
  `transfer-service` filtered to the SLO window, or **View in Discover**.
- A latency breach measured the same way: `scripts/slo-breach.sh` injects
  3000 ms latency and times the latency burn-rate alert (validation criteria
  9 and 10). Turn the bad release off first.

### What this shows

- **On-call SREs:** fewer pages, and the ones that arrive mean the budget is
  actually at risk.
- **Service owners and incident managers:** the same incident the engineers
  diagnosed appears as an objective in customer terms, with the budget it has
  cost and a visible point at which to act.
- **Risk and compliance:** detection time can be measured and reported.

### Limitations

The rule windows are shortened for the demo. Production windows are longer,
so detection takes longer; choosing them is a trade-off between speed and
false alarms. A new alert, and so a measurement, needs the previous alert to
have recovered: `reset-demo.sh --full` takes care of that.

Turn the bad release off afterwards with `scripts/fault-inject.sh bad-version
off`, or leave it for the next run and reset.

---

## Scenario 5: Observability as code

### Overview

Dashboards and alert rules created by hand drift between environments, and
there is no record of who changed what, or why. This scenario changes a
dashboard in Git and deploys it with Terraform, then exports a dashboard
built in the UI back to Git.

**What to look for:** the UI and Git stay usable side by side.

### Before you begin

A terminal in the repo root with Terraform access (`terraform plan` runs
without errors).

### Steps

| Step | Action | What you see |
|---|---|---|
| 1 | Open `dashboards/` in the repo, and the Terraform resource that deploys it through the Kibana Dashboards API on `terraform apply`. | The dashboard as JSON, reviewed in a pull request like any other change. It is redeployed when the file changes. |
| 2 | Kibana > Dashboards: open **Banking service overview**. | The same dashboard, deployed from Git. |
| 3 | Edit a file in `dashboards/` (for example change a panel title), then `git diff`, `git commit`, `terraform apply` (~30 s; only the dashboard resource changes). Refresh Kibana. | The change is live after commit and apply. The same flow works in every environment. |
| 4 | In Kibana, create or edit a dashboard by hand (add a panel) and save it. | Dashboards can still be built in the UI. |
| 5 | `scripts/export-dashboard.sh "<dashboard title>"`, then `git diff --stat`. | `dashboards/<slug>.json`, normalised (server metadata stripped, keys sorted) so the diff is clean and ready for review. |

To undo the scenario afterwards: `git revert HEAD` (the step 3 commit),
delete the file exported in step 5, delete the hand-made dashboard in
Kibana, and run `terraform apply`.

### Explore further

SLOs, burn-rate and threshold rules and their email actions, the ML job,
roles and users, and the AI triage agent and workflow are Terraform
resources too (`elasticstack` provider). The email connector is the Elastic
Cloud preconfigured one.

### What this shows

- **Platform engineers:** Kibana content is deployed the same way as the
  infrastructure, with review and history, and is the same in every
  environment.
- **Application developers:** dashboards can still be prototyped in the UI
  and brought into Git with one command.
- **Risk and compliance:** changes to alerting, SLOs and access roles have a
  review trail in Git.

---

## Appendix: other faults for scenario 2

Alternatives to the bad release in scenario 2, each showing a different kind
of incident. Turn the bad release off first (control panel > Bad release
**Off**) so each fault is the only one running.

| Fault | Command | Visible after |
|---|---|---|
| Bad release of transfer-service (scenario 2) | `scripts/fault-inject.sh bad-version on` | new version ~1-2 min, correlations ~5 min |
| [Slow database in accounts-ledger](#slow-database-in-accounts-ledger) | `scripts/fault-inject.sh slow-db on` | slow DB spans and WARN logs ~1 min |
| [Latency on transfer-service](#latency-on-transfer-service) | `scripts/fault-inject.sh latency on 1500` | alert ~1-2 min |
| [Errors in fraud-check](#errors-in-fraud-check) | `scripts/fault-inject.sh errors on 30` | error rate ~1 min, alert ~1-2 min |

### Slow database in accounts-ledger

A slowdown with no errors, where several services alert and only one is the
cause. Turn on: `scripts/fault-inject.sh slow-db on` (control panel > Slow DB
**On**). accounts-ledger adds `pg_sleep(0.8)` to balance lookups and a slow
duplicate-reference scan to every debit and credit: balances take ~0.8 s
longer and transfers ~1.6 s longer. Nothing fails.

| Step | Action | What you see |
|---|---|---|
| 1 | In the bank UI, refresh the balance and send a transfer. | Both succeed, but are noticeably slow. |
| 2 | Observability > Alerts. | Latency alerts for `accounts-ledger`, and for `transfer-service` and `web-banking`, which wait on it: three services alerting, one cause. |
| 3 | Service map: click `accounts-ledger` > Service details. | Alert badges along the chain; `accounts-ledger` is the deepest unhealthy service, next to its Postgres dependency. |
| 4 | Trace samples: pick a slow sample (or your transfer from step 1) and open the **Timeline** tab. Expand the `accounts-ledger` span and its Postgres child span. | The statement contains `pg_sleep`: the query where the time goes, in a trace that crosses Node.js, Java, .NET and Python. |
| 5 | Open the **Logs** tab. | `WARN Slow ledger query: ... took N ms (threshold 500 ms)` from accounts-ledger, alongside the lines from every other service in the trace (web-banking `transfer processed`, fraud-check `Scored transfer ...`, accounts-ledger `Posted debit ...`). |
| 6 | Discover > ES\|QL: the second and fourth [ES\|QL queries](#esql-queries). | All logs for the trace, and flat pod CPU: the database is waiting, not short of resources, so more nodes would not help. |

What this shows: the trace separates the services that are slow from the one
causing it, and the evidence is the exact query.

### Latency on transfer-service

A slowdown inside one service, where the services it calls are healthy. Turn
on: `scripts/fault-inject.sh latency on 1500` (control panel > Latency
**On**). transfer-service waits 1500 ms on every transfer before doing any
work. Balance checks do not go through transfer-service and are unaffected.

| Step | Action | What you see |
|---|---|---|
| 1 | In the bank UI, send a transfer, then refresh the balance. | The transfer takes 1.5 s or more; the balance is fast. The problem is on the transfer path. |
| 2 | Observability > Alerts. | Latency alerts for `transfer-service`, and for `web-banking`, which waits on it. |
| 3 | Service map. | An alert badge on `transfer-service`; its dependencies `fraud-check` and `accounts-ledger` are healthy, so the time is spent inside transfer-service. |
| 4 | Trace samples: pick a slow sample and open the **Timeline** tab. | The `POST /transfer` span is ~1.5 s long, but its calls to fraud-check and accounts-ledger take their normal time; the gap before the first child call is the delay. |
| 5 | Discover > ES\|QL: `FROM logs-*.otel-* \| WHERE service.name == "transfer-service" AND body.text LIKE "Fault config changed*"` | The `Fault config changed: LATENCY_MS=1500` line marks when the regression started. In a real incident, this is the config change or deployment to look for. |

What this shows: healthy dependencies narrow the search to one service, and a
log line ties the start of the regression to a change.

### Errors in fraud-check

Intermittent failures that start in one service and surface in several. Turn
on: `scripts/fault-inject.sh errors on 30` (control panel > Errors **On**).
30% of fraud-check calls hang for 200-600 ms and then fail with HTTP 500
(`FraudModelTimeoutException`). The transfer fails with them.

| Step | Action | What you see |
|---|---|---|
| 1 | In the bank UI, send a few transfers. | About one in three ends in "Transfer failed" (HTTP 500). |
| 2 | Observability > Alerts. | Error-rate alerts for `fraud-check`, `transfer-service` and `web-banking`. |
| 3 | Service map: click `fraud-check` > Service details. | `fraud-check` is the deepest service with an alert badge: the errors start there and travel up the call chain. |
| 4 | fraud-check > **Errors**. | The `FraudModelTimeoutException` group, with its stack trace, occurrences over time, and first and last seen. |
| 5 | Trace samples: open a failed sample (or your failed transfer from step 1) and its **Timeline** tab. | The error on the fraud-check span becomes an HTTP 500 in transfer-service, web-banking and the browser. |
| 6 | Open the **Logs** tab. | `Unhandled exception processing /score` from fraud-check, and the failure as it surfaced in web-banking (`transfer failed`). |
| 7 | Discover > ES\|QL: the third [ES\|QL query](#esql-queries). | Errors by service and version. |

What this shows: the origin of the errors is clear even when several services
alert, and the error group gives the stack trace and frequency.

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

### Trace-log correlation in Discover

The same correlation as the trace sample **Logs** tab (scenario 2, step 7),
done in Discover with ES|QL so every step is a query that can be shown, kept
or shared. Needs the bad release on (the state after a reset). Discover >
ES|QL mode, time picker **Last 15 minutes**. Replace `<trace.id>` with the
value copied in step 1 or 4 (hover the cell > **Copy value**).

| Step | Action | What you see |
|---|---|---|
| 1 | Run query A (failed transfers). Copy a `trace.id`. | `POST /transfer` requests answered with HTTP 500, all on `service.version` `2.0.0`. |
| 2 | Run query B (logs of that trace). | Three log lines from two services for the one request: `ERROR Ledger contract mismatch ...` from transfer-service, then `transfer failed` and `request errored` from web-banking. Each has the `span.id` of the span that was active when it was written. |
| 3 | Run query C (spans and logs of that trace, one timeline). | The spans (`POST /api/transfers` in web-banking, `POST /transfer` in transfer-service, both `Error`) followed by the log lines. The ~0.4 s between the start of `POST /transfer` and its `ERROR` log is the delay the bad release adds. If only log lines appear, the spans are still being indexed: run it again after a few seconds. |
| 4 | Log to trace: run query D (the error message), copy a `trace.id` and run query C with it. | Starting from a log line instead of a trace leads to the same request. |
| 5 | Run query E (error logs by version). | transfer-service `2.0.0` writes one error log per failed trace; web-banking writes two per trace for about the same number of traces. The web-banking errors are the same failed transfers seen from upstream, not a second problem. |

Query A, failed transfers:

```esql
FROM traces-*.otel-*
| WHERE service.name == "transfer-service" AND status.code == "Error"
| KEEP @timestamp, trace.id, name, service.version, http.response.status_code
| SORT @timestamp DESC
| LIMIT 10
```

Query B, logs of one trace:

```esql
FROM logs-*.otel-*
| WHERE trace.id == "<trace.id>" AND severity_text IS NOT NULL
| KEEP @timestamp, service.name, severity_text, span.id, body.text
| SORT @timestamp ASC
```

Query C, spans and logs of one trace (framework middleware spans left out):

```esql
FROM traces-*.otel-*, logs-*.otel-*
| WHERE trace.id == "<trace.id>" AND (data_stream.type == "traces" OR severity_text IS NOT NULL)
| WHERE NOT (data_stream.type == "traces" AND name LIKE "middleware*")
| EVAL type = data_stream.type, event = COALESCE(body.text, name), duration_ms = duration / 1000000
| KEEP @timestamp, type, service.name, severity_text, event, duration_ms, status.code
| SORT @timestamp ASC
```

Query D, from a log message to its traces:

```esql
FROM logs-*.otel-*
| WHERE body.text LIKE "Ledger contract mismatch*"
| KEEP @timestamp, service.name, service.version, trace.id, span.id, body.text
| SORT @timestamp DESC
| LIMIT 10
```

Query E, error logs and the traces they belong to, by version:

```esql
FROM logs-*.otel-*
| WHERE TO_LOWER(severity_text) == "error" AND trace.id IS NOT NULL
| STATS error_logs = COUNT(*), traces = COUNT_DISTINCT(trace.id) BY service.name, service.version
| SORT error_logs DESC
```

`severity_text IS NOT NULL` leaves out the exception events that also land in
`logs-*.otel-*` (they have no severity); the APM error pages show those.
Severity is upper case in Java (`ERROR`) and lower case in Node.js (`error`),
hence `TO_LOWER` in query E.

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
scripts/reset-demo.sh          # other faults off, fx-rates removed, load 5 req/s, then the bad release on
scripts/fault-inject.sh status
```

`--no-fault` leaves every fault off instead (`APP_VERSION=1.4.2
BAD_RELEASE=false`), for a fault-free baseline.

- The plain reset does not clear alerts. If the bad release was already
  running, its burn-rate alert may still be active, and no new alert is
  raised for scenario 4. Use `--full` before a run.
- Active alerts recover on their own: threshold alerts ~1-2 min after the
  fault stops, burn-rate alerts ~5-6 min. Wait for recovery (or use `--full`)
  before running `scripts/slo-breach.sh` again.
- The consumed SLO error budget only returns as the time window rolls
  forward. Use `--full` for a clean budget.
- Set the time picker back to Last 15 minutes to show the healthy baseline.

Before a fresh run:

```bash
scripts/reset-demo.sh --full   # also resets both SLOs, redeploys dashboards from Git,
                               # waits (up to 6 min) for alerts to recover, deletes the
                               # alert history, cases, AI triage workflow runs and
                               # conversations, then turns the bad release on
```

The deletes cannot be undone. Alerts and workflow runs have no delete API, so
they are removed from Kibana's internal indices (the workflow runs by the
`demo-reset` user, which only has access to those indices). Traces, logs and
metrics are kept: set the time picker to Last 15 minutes.

`--no-wait` skips the wait for recovery; right after a fault an alert can then
fire once more and recover within ~5-6 min. `--wait-timeout MIN` changes the
wait. ML anomaly results and historical telemetry are kept.

When finished:

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
| kubectl / terraform times out reaching the EKS API | The API only allows the IP you applied from. If your IP changed (new network, VPN), run `scripts/reset-demo.sh` (it re-applies the allowlists for the new IP), or set `eks_api_allowed_cidrs` in `terraform/local.auto.tfvars` |
| kubectl cannot reach `banking` | `aws eks update-kubeconfig --name $(terraform output -raw cluster_name) --region $(terraform output -raw aws_region) --profile $(terraform output -raw aws_profile)` |
| No traces for a service | Pod has an `opentelemetry-auto-instrumentation-*` init container; `kubectl -n opentelemetry-operator-system get pods`; load generator running |
| A service is missing its init container after nodes were replaced | The pod started before the OTel Operator was ready. `kubectl -n banking rollout restart deployment/<service>`, then `scripts/validate.sh --only 3` |
| Trace sample Logs tab is empty, or a service is missing from it | `scripts/validate.sh --only 5` (shows `log->trace=no` per service). Check the service's log export setting in [How log correlation works](#how-log-correlation-works); the time picker must cover the trace |
| Bank UI spans missing (`web-banking-frontend` not in APM) | Browser dev tools > Network: `POST /v1/traces` should return 200. 403 means the request bypassed CloudFront; 503 means the web-banking pod has no `OTEL_EXPORTER_OTLP_ENDPOINT` (not auto-instrumented). `scripts/test-runbook.sh` check R7 posts a test span through the same path |
| Bank UI returns 403 from CloudFront | Your IP is not in `control_panel_allowed_cidrs` (the WAF ACL is shared with the control panel). Run `scripts/reset-demo.sh`, which re-applies it for your current IP; the change reaches CloudFront within a minute or two |
| No new burn-rate alert | A previous alert is still active; wait for recovery or reset the SLO |
| AI Assistant not responding | Managed LLM connector in Stack Management > Connectors; user is `demo-sre` |
| No AI triage case after ~5 min | Workflows > Banking alert triage > Executions: a failed step shows its error. No execution at all: the error-rate alert started before the workflow existed or is still active from an earlier run (only new alerts trigger it); run `scripts/reset-demo.sh --full` |
