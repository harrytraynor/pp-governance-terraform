terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    powerplatform = {
      source  = "microsoft/power-platform"
      version = "4.2.1"
    }
  }
}
