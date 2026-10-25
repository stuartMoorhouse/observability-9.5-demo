# Demo Steps: Elastic Observability 9.5

A short checklist of the steps for each demo scenario. For the full talk track, ES|QL queries and troubleshooting, see
[docs/runbook.md](docs/runbook.md).

Run scripts from the repo root. Present as `demo-sre`. Time picker: Last 15 minutes.

Every scenario step that uses `fault-inject.sh`, `onboard-service.sh`, `generate-load.sh` or a plain
`reset-demo.sh` has a matching button in the demo control panel
(`terraform -chdir=terraform output -raw control_panel_url`). Use the page instead of a terminal while presenting.

## Prep (T-60 min)

1. `scripts/validate.sh` - all checks pass.
2. `scripts/reset-demo.sh --full` - faults off, fx-rates removed, SLOs reset, alerts cleared.
3. Log in to three browser profiles: `elastic`, `demo-sre`, `demo-viewer`
   (`terraform -chdir=terraform output -raw <user>_password`).
4. Open tabs: demo control panel, Service inventory, Service map, SLOs, Alerts, Discover (ES|QL), Dashboards.
5. About 15 min before scenario 4, start `scripts/slo-breach.sh --keep-fault` (or control panel > SLO breach **Start**, which skips
   the detection-delay measurement). This fault also drives scenarios 2 and 3.

## 1. Self-service K8s onboarding (~7 min)

**Point:** add one annotation to a service and it gets traces, K8s views, the SLO, alerting and ML with no ticket and no Kibana changes.

1. Service inventory: 4 services, no OTel SDK in any image.
2. Show the `instrumentation.opentelemetry.io/inject-python` annotation in
   `charts/fx-rates/templates/deployment.yaml`.
3. Control panel > **Onboard** (or `scripts/onboard-service.sh`, a Helm install, as the team's pipeline would run it).
4. Infrastructure > Kubernetes, namespace `banking`: the new pod appears.
5. Service inventory: `fx-rates` appears. Service map: a new `transfer-service -> fx-rates` edge.
6. SLOs: the existing SLO, grouped by `service.name`, now has an `fx-rates` instance.
7. Rules and the ML job are scoped to the environment, so they already cover `fx-rates`.

## 2. Incident to root cause (~10 min)

**Point:** go from the alert to the evidence in a few clicks, across services written in four languages.

Start the fault 5 min ahead. Use `bad-version` for the correlations story and `slow-db` for the trace story:
Control panel > Bad release / Slow DB **On** (or `scripts/fault-inject.sh bad-version on` / `slow-db on`).

1. **Alert:** Observability > Alerts > open the `transfer-service` alert.
2. **Service map:** the affected node shows alert, SLO and anomaly badges.
3. **Service overview:** the latency and failure charts show version `2.0.0` alongside `1.4.2`.
4. **Correlations:** `POST /transfer` > Latency / Failed transaction correlations. `service.version: 2.0.0` ranks first.
5. **Trace:** open a slow sample's waterfall. It shows the slow Postgres span (slow-db) or the exception (bad-version).
6. **Logs:** open the logs for this trace (filtered by `trace.id`).
7. **Metrics in ES|QL:** in Discover, run the queries from the runbook (traces by version, errors by service, pod CPU).

## 3. AI-assisted triage (~8 min)

**Point:** AI speeds up triage, but every core feature works without it, and roles decide who can use AI.

Keep the fault running.

1. As `demo-sre`: from the alert, open the AI Assistant (or Agent Builder > observability agent).
2. Prompt: *"Investigate the latency alert on transfer-service in banking-demo over the last 30 minutes. Find the root cause and suggest next steps."* Point out the agent's tool calls: these are the same steps as scenario 2.
3. Ask a follow-up for an ES|QL query showing the error rate by `service.version`, then run it in Discover.
4. **AI off:** switch to `demo-viewer`. The alert, map, correlations, trace and logs all still work, but there is no AI Assistant button and no Agent Builder.
5. **Per-role restriction:** Stack Management > Roles, `demo-viewer` compared with `demo-sre`. Both roles are defined in Terraform.

The LLM is the Elastic Managed LLM, so there is no external key and no secret in the repo.

## 4. SLO burn-rate alerting (~8 min + lead time)

**Point:** alert on error-budget burn, which is what customers feel, and measure how long detection takes.

Started in Prep: `scripts/slo-breach.sh --keep-fault` (3000 ms latency on `transfer-service`).

1. SLOs: transfer SLO > `transfer-service`. Show the target, the window and the remaining budget.
2. SLO details: SLI chart, budget burn-down and the multi-window burn-rate rule.
3. Alerts: open the burn-rate alert (burn rate, windows, reason).
4. Show the email notification and the email connector's execution log.
5. `results/slo-breach-<ts>.json`: `detection_delay_seconds` (typically ~4 min).
6. **Drill-through:** from the SLO, open the underlying events (APM service page or View in Discover).

End: control panel > SLO breach **Stop** (or `scripts/fault-inject.sh latency off`).

## 5. Observability as code (~7 min)

**Point:** dashboards, SLOs, rules, connectors, ML jobs and roles are all in Git, and none were clicked together.

1. Show `dashboards/*.json` and the Terraform resource that deploys them through the Dashboards API.
2. Kibana > Dashboards: open the banking dashboard.
3. Edit a panel title in `dashboards/`, then `git diff` > `git commit` > `terraform -chdir=terraform apply`. Refresh Kibana to show the change.
4. In Kibana, add a panel to a dashboard and save it.
5. `scripts/export-dashboard.sh "<title>"` writes normalized JSON to `dashboards/`. Run `git diff --stat`.
6. Optional: ask Agent Builder to create a dashboard from natural language.

Afterwards, revert the edits: `git checkout -- dashboards/ && terraform -chdir=terraform apply`.

## Reset and teardown

- Between runs: control panel > **Reset demo** or `scripts/reset-demo.sh` (use `--full` for a clean SLO budget and no
  active alerts; the panel cannot do that part).
- After the meeting: `terraform -chdir=terraform destroy` (before the `keep-until` tag date).
