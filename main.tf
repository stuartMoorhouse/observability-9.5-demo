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

  # expires_at / owner / purpose flow to every AWS resource from local.auto.tfvars.
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
  eks_api_allowed_cidrs = length(var.eks_api_allowed_cidrs) > 0 ? var.eks_api_allowed_cidrs : [
    "${trimspace(data.http.my_ip.response_body)}/32",
  ]

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

module "eks" {
  source = "./modules/eks"

  prefix             = var.prefix
  aws_region         = var.aws_region
  aws_profile        = var.aws_profile
  kubernetes_version = var.kubernetes_version

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

module "otel_k8s" {
  source = "./modules/otel-k8s"

  elasticsearch_endpoint   = module.elastic_cloud.elasticsearch_endpoint
  kube_stack_chart_version = var.kube_stack_chart_version
  # Resolved exact version (e.g. 9.5.5) even when var.elastic_version is "9.5.x".
  elastic_version = module.elastic_cloud.elastic_version

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
  dashboards_dir         = "${path.root}/dashboards"
}

module "demo_app" {
  source = "./modules/demo-app"

  prefix              = var.prefix
  aws_region          = var.aws_region
  aws_profile         = var.aws_profile
  instrumentation_ref = module.otel_k8s.instrumentation_ref
  image_build_tool    = var.image_build_tool
  image_platform      = var.image_platform
  app_version         = "1.4.2"
  loadgen_rate        = var.loadgen_rate

  # The Instrumentation CR must exist before pods start, or they are not injected.
  depends_on = [module.eks, module.otel_k8s]
}
