# Elastic Observability 9.5 Demo: Digital Banking on EKS

A repeatable demo environment for a banking audience, provisioned with a single
`terraform apply`. A small payments application runs on Amazon EKS, is
auto-instrumented by the OpenTelemetry Operator (no SDK in the images), and
ships logs, metrics and traces through the Elastic Distribution of
OpenTelemetry (EDOT) to Elastic Cloud Hosted 9.5.

The demo covers five scenarios:

1. Self-service Kubernetes onboarding of a new service
2. Incident to root cause (alert, service map, correlations, traces, logs, ES|QL)
3. AI-assisted triage, AI off, and per-role AI restriction
4. SLO burn-rate alerting with a measured detection delay
5. Observability as code (dashboards from Git, export from the UI)

The click path and talk track for each scenario are in
[docs/runbook.md](docs/runbook.md).

## Architecture

```
                         Amazon EKS (eu-north-1, spot nodes, fck-nat)
 +-------------------------------------------------------------------------------+
 |  namespace: banking                                                           |
 |                                                                               |
 |  k6 loadgen --> web-banking --> transfer-service --+--> fraud-check           |
 |                 (Node.js BFF)   (Java, Spring Boot)|    (.NET, ASP.NET Core)  |
 |                                                    +--> accounts-ledger       |
 |                                                    |    (Python, FastAPI)     |
 |                                                    |      --> Postgres        |
 |                                                    +--> fx-rates (scenario 1) |
 |                                                         (Python, FastAPI)     |
 |   ConfigMap fault-config (LATENCY_MS, ERROR_RATE, SLOW_DB) read every 5 s     |
 |                                                                               |
 |  namespace: opentelemetry-operator-system                                     |
 |   OTel Operator (auto-instrumentation via pod annotation)                     |
 |   EDOT collectors: DaemonSet (node, pod, logs) + cluster collector            |
 |   (opentelemetry-kube-stack Helm chart)                                       |
 +--------------------------------------|----------------------------------------+
                                        | OTLP -> Elasticsearch (API key)
                                        v
 +-------------------------------------------------------------------------------+
 |  Elastic Cloud Hosted 9.5 (AWS eu-north-1, 2 zones)                           |
 |   Elasticsearch hot tier + dedicated ML node, Kibana                          |
 |   Terraform-managed content: SLO (groupBy service.name), burn-rate and        |
 |   threshold rules, email connector, ML anomaly job, demo-sre / demo-viewer    |
 |   roles and users, dashboards (Dashboards API)                                |
 |   Elastic Managed LLM for the AI Assistant / Agent                            |
 +-------------------------------------------------------------------------------+
```

Terraform layout: `main.tf`, `variables.tf`, `outputs.tf` under `terraform/`,
modules under `terraform/modules/` (`eks`, `elastic-cloud`, `otel-k8s`, `demo-app`,
`kibana-content`). Application source is under `apps/`, Helm charts under
`charts/`, dashboards-as-code JSON under `dashboards/`, operational scripts
under `scripts/`, measured results under `results/`.

## Prerequisites

| Tool | Notes |
|---|---|
| AWS CLI v2 | A named profile for the target account. Verify with `aws sts get-caller-identity --profile <your-aws-profile>` before applying. Watch for `AWS_ACCESS_KEY_ID` etc. in your environment overriding the profile. |
| Elastic Cloud API key | Created in your Elastic Cloud organization (Organization > API keys) and exported as `EC_API_KEY`. The key selects the organization. |
| Terraform >= 1.5 | |
| kubectl | Kubeconfig is written by Terraform (`aws eks update-kubeconfig`). |
| helm 3 | Used by `scripts/onboard-service.sh`. |
| docker or podman | Images are built for `linux/arm64` (Graviton nodes, native on Apple Silicon) and pushed to ECR. Set `image_platform = "linux/amd64"` for x86 nodes; that needs emulation on Apple Silicon. |
| jq, curl | Used by all scripts. |
| gitleaks (optional) | Secrets scan for `scripts/validate.sh` (criterion 13). |

k6 is not needed locally: the load generator runs in the cluster.

## Setup

1. Create your local variables file (gitignored):

   ```bash
   cd terraform
   cp local.auto.tfvars.example local.auto.tfvars
   # edit: elastic_cloud_organization, aws_profile, elastic_version (exact 9.5.x patch),
   #       alert_email_recipients, tags (division, org, team, project, keep-until)
   ```

2. Export credentials:

   ```bash
   export EC_API_KEY=...            # from your Elastic Cloud organization
   aws sts get-caller-identity --profile <your-aws-profile>
   ```

3. Provision (from `terraform/`):

   ```bash
   terraform init
   terraform validate
   terraform plan -out tfplan
   terraform apply tfplan
   ```

   Expect roughly 30-40 minutes end to end: EKS cluster and node group
   (~15 min), Elastic Cloud deployment (~5 min), image builds and pushes
   (~5 min; longer for linux/amd64 on Apple Silicon), Helm releases and Kibana content.

   **Elastic Cloud timeout handling.** The `ec_deployment` resource can take
   4-5 minutes and Terraform may time out before it finishes. If that
   happens: wait 5 minutes, run `terraform refresh`, then `terraform plan` to
   confirm the state. Do not run another `terraform apply` straight after a
   timeout; it can create a duplicate deployment.

4. Check the outputs and log in:

   ```bash
   terraform output kibana_url
   terraform output -raw elastic_password        # superuser, keep private
   terraform output -raw demo_sre_password       # user demo-sre (AI enabled)
   terraform output -raw demo_viewer_password    # user demo-viewer (no AI)
   ```

   The scripts read these values from `terraform output` at run time and keep
   passwords in memory only. `shared/env.json` caches the non-secret endpoints
   and readiness flags.

Network access: the public EKS API endpoint only accepts the public IP of the
machine running `terraform apply` (detected automatically). If you present from
a different network, re-run `terraform apply` there first, or list CIDRs in
`eks_api_allowed_cidrs`.

## Running the scenarios

See [docs/runbook.md](docs/runbook.md). Script summary:

| Script | Purpose |
|---|---|
| `scripts/fault-inject.sh <latency\|errors\|slow-db\|bad-version\|all> <on\|off> [value]` | Toggle faults; `status` shows the current state |
| `scripts/onboard-service.sh [install\|uninstall]` | Scenario 1: deploy fx-rates and time its first telemetry |
| `scripts/slo-breach.sh [--keep-fault]` | Scenario 4: drive a burn-rate breach, write `results/slo-breach-<ts>.json` |
| `scripts/export-dashboard.sh <id\|title>` | Scenario 5: export a UI dashboard to `dashboards/<slug>.json` |
| `scripts/generate-load.sh <rate\|start\|stop\|status>` | Control the in-cluster k6 load generator |
| `scripts/reset-demo.sh` | Faults off, baseline release, remove fx-rates, restore load. `--full` also resets SLOs, redeploys dashboards from Git and waits for alerts to clear |
| `scripts/validate.sh [--scenarios] [--slo-breach]` | Acceptance checks, writes `results/validate-<ts>.json` |

## Validation

```bash
scripts/validate.sh                 # read-only checks (criteria 2-5, 10-13)
scripts/validate.sh --scenarios     # adds 6-8: onboarding and fault scenarios (~15 min)
scripts/validate.sh --all           # adds 9: SLO breach (up to 30 min more)
```

Each criterion prints PASS, FAIL or SKIP with detail, and the run exits
non-zero on any FAIL. Scenario checks turn faults off when they finish.
Criterion 14 (clean destroy) is checked by running `terraform destroy`.

## Teardown

```bash
scripts/reset-demo.sh      # optional: removes the out-of-band fx-rates Helm release
terraform destroy
```

- Every AWS resource carries the org tags (including `keep-until`) from `terraform/local.auto.tfvars`.
  Check it against the calendar and destroy before that date; nothing deletes
  resources automatically.
- The VPC has a destroy-time cleanup step for security groups and network
  interfaces created outside Terraform (for example by GuardDuty). If a
  destroy still fails with `DependencyViolation`, wait a few minutes and run
  `terraform destroy` again.
- After destroy, confirm no tagged resources remain:
  `aws resourcegroupstaggingapi get-resources --tag-filters Key=keep-until --profile <your-aws-profile> --region <aws_region>`.

## Repository hygiene

- `local.auto.tfvars` holds your organization, AWS profile, email recipients
  and tags. It is gitignored; only `local.auto.tfvars.example` is committed.
- Secrets come from the environment (`EC_API_KEY`, AWS profile) or are
  generated by Terraform (`random_password`) and exposed only as sensitive
  outputs. Terraform state contains these values; keep it local or in a
  private backend.
- `scripts/validate.sh` criterion 13 scans committed files with gitleaks and
  checks that no value from `local.auto.tfvars` appears in them.
