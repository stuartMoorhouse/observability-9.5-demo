terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" # modules/demo-app requires >= 6.0; eks module ~> 21
    }
    ec = {
      source  = "elastic/ec"
      version = "~> 0.12"
    }
    elasticstack = {
      source  = "elastic/elasticstack"
      version = ">= 0.11"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.30"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

# -----------------------------------------------------------------------------
# Providers
# -----------------------------------------------------------------------------

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  # Org tags (division, org, team, project, keep-until) flow to every AWS resource from local.auto.tfvars.
  default_tags {
    tags = var.tags
  }
}

# AWS WAF for CloudFront (the demo-control-panel IP allowlist) must be created in us-east-1.
provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.aws_profile

  default_tags {
    tags = var.tags
  }
}

# Authenticates with EC_API_KEY; the key determines the Elastic Cloud organization.
provider "ec" {}

# Elastic superuser from the ECH deployment (demo only).
provider "elasticstack" {
  elasticsearch {
    endpoints = [module.elastic_cloud.elasticsearch_endpoint]
    username  = module.elastic_cloud.elasticsearch_username
    password  = module.elastic_cloud.elasticsearch_password
  }

  kibana {
    endpoints = [module.elastic_cloud.kibana_endpoint]
    username  = module.elastic_cloud.elasticsearch_username
    password  = module.elastic_cloud.elasticsearch_password
  }
}

# Public IP of the machine running Terraform, used to lock down the EKS API endpoint.
data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  my_ip_cidr = "${trimspace(data.http.my_ip.response_body)}/32"

  eks_api_allowed_cidrs       = length(var.eks_api_allowed_cidrs) > 0 ? var.eks_api_allowed_cidrs : [local.my_ip_cidr]
  control_panel_allowed_cidrs = length(var.control_panel_allowed_cidrs) > 0 ? var.control_panel_allowed_cidrs : [local.my_ip_cidr]

  eks_exec_args = [
    "eks", "get-token",
    "--cluster-name", module.eks.cluster_name,
    "--region", var.aws_region,
    "--profile", var.aws_profile,
  ]
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = module.eks.cluster_ca_certificate

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.eks_exec_args
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = module.eks.cluster_ca_certificate

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.eks_exec_args
    }
  }
}

# -----------------------------------------------------------------------------
# Modules
# -----------------------------------------------------------------------------

# Postgres credentials live here rather than in demo-app because both demo-app (the
# database) and otel-k8s (the postgresql receiver) need them, and demo-app already
# depends on otel-k8s.
resource "random_password" "postgres" {
  length  = 32
  special = false
}

# Keep the existing password; regenerating it would break the initialised database volume.
moved {
  from = module.demo_app.random_password.postgres
  to   = random_password.postgres
}

locals {
  postgres = {
    username = "ledger"
    password = random_password.postgres.result
    database = "ledger"
    # demo-app deploys the postgres Service into the "banking" namespace.
    endpoint = "postgres.banking.svc.cluster.local:5432"
  }
}

module "eks" {
  source = "./modules/eks"

  prefix             = var.prefix
  aws_region         = var.aws_region
  aws_profile        = var.aws_profile
  kubernetes_version = var.kubernetes_version
  node_architecture  = split("/", var.image_platform)[1] # nodes follow the image platform
  tags               = var.tags

  cluster_endpoint_public_access_cidrs = local.eks_api_allowed_cidrs
}

module "elastic_cloud" {
  source = "./modules/elastic-cloud"

  prefix                     = var.prefix
  aws_region                 = var.aws_region
  elastic_version            = var.elastic_version
  elastic_cloud_organization = var.elastic_cloud_organization
  tags                       = var.tags
}

# S3 snapshot repository in the AWS account plus the demo-logs ILM policy
# (hot -> frozen -> delete) for all logs, metrics and traces.
module "data_lifecycle" {
  source = "./modules/data-lifecycle"

  prefix        = var.prefix
  deployment_id = module.elastic_cloud.deployment_id
}

module "otel_k8s" {
  source = "./modules/otel-k8s"

  elasticsearch_endpoint   = module.elastic_cloud.elasticsearch_endpoint
  kube_stack_chart_version = var.kube_stack_chart_version
  # Resolved exact version (e.g. 9.5.5) even when var.elastic_version is "9.5.x".
  elastic_version = module.elastic_cloud.elastic_version
  postgres        = local.postgres

  depends_on = [module.eks]
}

module "kibana_content" {
  source = "./modules/kibana-content"

  kibana_endpoint        = module.elastic_cloud.kibana_endpoint
  elasticsearch_endpoint = module.elastic_cloud.elasticsearch_endpoint
  elastic_username       = module.elastic_cloud.elasticsearch_username
  elastic_password       = module.elastic_cloud.elasticsearch_password
  alert_email_recipients = var.alert_email_recipients
  environment            = "banking-demo"
  dashboards_dir         = "${path.root}/../dashboards"
  traces_ready           = tostring(module.demo_app.release_revision)
}

module "demo_app" {
  source = "./modules/demo-app"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  prefix              = var.prefix
  aws_region          = var.aws_region
  aws_profile         = var.aws_profile
  instrumentation_ref = module.otel_k8s.instrumentation_ref
  image_build_tool    = var.image_build_tool
  image_platform      = var.image_platform
  app_version         = "1.4.2"
  loadgen_rate        = var.loadgen_rate
  postgres = {
    username = local.postgres.username
    password = local.postgres.password
    database = local.postgres.database
  }

  kibana_url                  = module.elastic_cloud.kibana_endpoint
  control_panel_allowed_cidrs = local.control_panel_allowed_cidrs
  tags                        = var.tags

  # The Instrumentation CR must exist before pods start, or they are not injected.
  depends_on = [module.eks, module.otel_k8s]
}
