terraform {
  required_version = ">= 1.5"
  required_providers {
    ec = {
      source  = "elastic/ec"
      version = "~> 0.12"
    }
  }
}
