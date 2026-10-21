terraform {
  required_version = ">= 1.6"

  required_providers {
    elasticstack = {
      source  = "elastic/elasticstack"
      version = ">= 0.16.6"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}
