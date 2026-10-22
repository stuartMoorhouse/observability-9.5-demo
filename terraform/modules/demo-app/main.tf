locals {
  apps_dir  = abspath("${path.module}/../../../apps")
  chart_dir = abspath("${path.module}/../../../charts/demo-app")
  namespace = "banking"

  services = toset(["web-banking", "transfer-service", "fraud-check", "accounts-ledger", "fx-rates", "demo-control-panel"])

  # Built here but not part of the demo-app chart: fx-rates is deployed during
  # scenario 1, demo-control-panel has its own release below.
  chart_services = setsubtract(local.services, ["fx-rates", "demo-control-panel"])

  # Content hash of each service's source dir (build outputs excluded). Used as the
  # image tag, so ECR tags can stay IMMUTABLE and a rebuild only happens on change.
  source_hash = {
    for svc in local.services : svc => substr(sha1(join("", [
      for f in sort(fileset("${local.apps_dir}/${svc}", "**")) :
      "${f}:${filesha1("${local.apps_dir}/${svc}/${f}")}"
      if !can(regex("(^|/)(node_modules|target|bin|obj|__pycache__|\\.venv)/", f))
    ])), 0, 12)
  }

  # Architecture in the tag: tags are immutable and the ECR skip check is per tag,
  # so switching platform must produce a new tag rather than reuse the old image.
  arch      = split("/", var.image_platform)[1]
  image_tag = { for svc in local.services : svc => "${var.app_version}-${local.source_hash[svc]}-${local.arch}" }
  registry  = split("/", aws_ecr_repository.app["web-banking"].repository_url)[0]
}

# ---------------------------------------------------------------------------
# ECR
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "app" {
  for_each = local.services

  name                 = "${var.prefix}/${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # demo teardown: delete repos with images

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS" # AWS managed aws/ecr key; CMK is out of scope for v1
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 10 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ---------------------------------------------------------------------------
# Image build + push (local container CLI). Re-runs when the source hash changes.
# ---------------------------------------------------------------------------
resource "null_resource" "image" {
  for_each = local.services

  triggers = {
    source_hash = local.source_hash[each.key]
    repository  = aws_ecr_repository.app[each.key].repository_url
    platform    = var.image_platform
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      TOOL      = var.image_build_tool
      PLATFORM  = var.image_platform
      PROFILE   = var.aws_profile
      REGION    = var.aws_region
      REGISTRY  = local.registry
      REPO_NAME = aws_ecr_repository.app[each.key].name
      IMAGE     = "${aws_ecr_repository.app[each.key].repository_url}:${local.image_tag[each.key]}"
      TAG       = local.image_tag[each.key]
      CONTEXT   = "${local.apps_dir}/${each.key}"
    }
    command = <<-EOT
      set -euo pipefail
      if aws ecr describe-images --profile "$PROFILE" --region "$REGION" \
           --repository-name "$REPO_NAME" --image-ids imageTag="$TAG" >/dev/null 2>&1; then
        echo "$IMAGE already in ECR, skipping build"
        exit 0
      fi
      aws ecr get-login-password --profile "$PROFILE" --region "$REGION" \
        | "$TOOL" login --username AWS --password-stdin "$REGISTRY"
      "$TOOL" build --platform "$PLATFORM" -t "$IMAGE" "$CONTEXT"
      "$TOOL" push "$IMAGE"
    EOT
  }
}

# ---------------------------------------------------------------------------
# Kubernetes: namespace, Postgres credentials, demo-app chart
# ---------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "banking" {
  metadata {
    name = local.namespace
    labels = {
      "app.kubernetes.io/part-of" = "banking-demo"
    }
  }
}

resource "kubernetes_secret_v1" "postgres" {
  metadata {
    name      = "postgres-credentials"
    namespace = kubernetes_namespace_v1.banking.metadata[0].name
  }

  data = {
    username = var.postgres.username
    password = var.postgres.password
    database = var.postgres.database
  }

  type = "Opaque"
}

resource "helm_release" "demo_app" {
  name      = "demo-app"
  chart     = local.chart_dir
  namespace = kubernetes_namespace_v1.banking.metadata[0].name

  wait    = true
  timeout = 900
  replace = true # reuse the name if a previous install failed (e.g. timed out) and was left behind

  values = [yamlencode({
    instrumentationRef = var.instrumentation_ref
    appVersion         = var.app_version
    loadgen = {
      rate = var.loadgen_rate
    }
    services = {
      for svc in local.chart_services : svc => merge(
        {
          image = {
            repository = aws_ecr_repository.app[svc].repository_url
            tag        = local.image_tag[svc]
          }
        },
        # The operator only knows the x64 .NET runtimes and points CORECLR_PROFILER_PATH
        # at linux-x64. It keeps a value the pod already sets, so set the path for the
        # node architecture here (the instrumentation image ships linux-arm64 too).
        svc == "fraud-check" ? {
          env = {
            CORECLR_PROFILER_PATH = "/otel-auto-instrumentation-dotnet/linux-${local.arch == "arm64" ? "arm64" : "x64"}/OpenTelemetry.AutoInstrumentation.Native.so"
          }
        } : {}
      )
    }
  })]

  depends_on = [
    null_resource.image,
    kubernetes_secret_v1.postgres,
  ]
}

# ---------------------------------------------------------------------------
# demo-control-panel: presenter web page that triggers the scenarios in-cluster.
# Exposed through a Classic Load Balancer restricted to var.control_panel_allowed_cidrs.
# ---------------------------------------------------------------------------

# fx-rates objects rendered from the same chart scripts/onboard-service.sh installs,
# so the control panel's "Onboard" button deploys exactly what the script would.
data "helm_template" "fx_rates" {
  name      = "fx-rates"
  chart     = abspath("${path.module}/../../../charts/fx-rates")
  namespace = kubernetes_namespace_v1.banking.metadata[0].name

  values = [yamlencode({
    image              = "${aws_ecr_repository.app["fx-rates"].repository_url}:${local.image_tag["fx-rates"]}"
    instrumentationRef = var.instrumentation_ref
    appVersion         = var.app_version
  })]
}

locals {
  fx_rates_objects = [
    for doc in split("\n---\n", "\n${data.helm_template.fx_rates.manifest}\n") : yamldecode(doc)
    if try(yamldecode(doc), null) != null
  ]
}

resource "helm_release" "demo_control_panel" {
  name      = "demo-control-panel"
  chart     = abspath("${path.module}/../../../charts/demo-control-panel")
  namespace = kubernetes_namespace_v1.banking.metadata[0].name

  wait    = true # also waits for the load balancer hostname
  timeout = 600
  replace = true

  values = [yamlencode({
    image = {
      repository = aws_ecr_repository.app["demo-control-panel"].repository_url
      tag        = local.image_tag["demo-control-panel"]
    }
    allowedCidrs     = var.control_panel_allowed_cidrs
    loadBalancerTags = join(",", [for k, v in var.tags : "${k}=${v}"])
    kibanaUrl        = var.kibana_url
    baseVersion      = var.app_version
    defaultLoadRate  = var.loadgen_rate
    fxRatesManifests = jsonencode(local.fx_rates_objects)
  })]

  depends_on = [
    null_resource.image,
    helm_release.demo_app,
  ]
}

data "kubernetes_service_v1" "demo_control_panel" {
  metadata {
    name      = "demo-control-panel"
    namespace = helm_release.demo_control_panel.namespace
  }

  depends_on = [helm_release.demo_control_panel]
}
