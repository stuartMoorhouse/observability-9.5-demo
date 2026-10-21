locals {
  ec_region = "aws-${var.aws_region}"

  # "9.5.x" -> ^9\.5\.[0-9]+$ (latest 9.5 patch); "9.5.2" -> ^9\.5\.2$ (exact).
  version_regex = "^${replace(replace(var.elastic_version, ".", "\\."), "x", "[0-9]+")}$"

  # ECH tag keys/values: keep to simple strings.
  deployment_tags = merge(var.tags, {
    name         = var.prefix
    organization = var.elastic_cloud_organization
  })
}

data "ec_stack" "this" {
  version_regex = local.version_regex
  region        = local.ec_region
  # Pin the resolved version in state so a new 9.5 patch does not trigger an
  # upgrade on the next apply. To move to a newer patch, set elastic_version to
  # the exact version (or temporarily set lock = false) and apply.
  lock = true
}

# The organization is NOT selected by Terraform: the ec provider authenticates
# with EC_API_KEY and the deployment is created in whichever organization that
# key was created in. var.elastic_cloud_organization is a tag and a reminder;
# create the key in the intended organization before applying.
check "elastic_cloud_organization_set" {
  assert {
    condition     = trimspace(var.elastic_cloud_organization) != "" && !startswith(var.elastic_cloud_organization, "<")
    error_message = "Set elastic_cloud_organization in local.auto.tfvars and make sure EC_API_KEY was created in that organization; the key, not this value, decides where the deployment is created."
  }
}

resource "ec_deployment" "this" {
  name                   = var.prefix
  region                 = local.ec_region
  version                = data.ec_stack.this.version
  deployment_template_id = var.deployment_template_id

  elasticsearch = {
    # No autoscaling: fixed sizes keep cost predictable and ML stays at 1 node.
    autoscale = false

    hot = {
      size          = var.hot_size
      size_resource = "memory"
      zone_count    = 2
      autoscaling   = {}
    }

    ml = {
      size          = var.ml_size
      size_resource = "memory"
      zone_count    = 1
      autoscaling   = {}
    }
  }

  kibana = {
    size          = var.kibana_size
    size_resource = "memory"
    zone_count    = 2
  }

  # No integrations_server: EDOT collectors write directly to Elasticsearch
  # with the elasticsearch exporter (APM data via the ES exporter in OTel mode).

  tags = local.deployment_tags
}
