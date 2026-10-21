terraform {
  required_version = ">= 1.6"

  required_providers {
    elasticstack = {
      source  = "elastic/elasticstack"
      version = ">= 0.16.6"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.30.0"
    }
  }
}
