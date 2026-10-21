terraform {
  required_version = ">= 1.6.0"

  required_providers {
    powerplatform = {
      source  = "microsoft/power-platform"
      version = "4.2.1"
    }
  }

  # Values live in backend.hcl, which is not committed.
  # A laptop test with no storage account can switch this block to backend "local" {}.
  # Run terraform init -reconfigure after changing it, and do not commit that edit.
  backend "azurerm" {}
}
