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

  # Values live in backend.hcl, which is not committed.
  # One state key per cost centre: -backend-config=key=lanes/<slug>.tfstate.
  # Fan-in environments and tier data policies use lanes/shared.tfstate.
  # A local backend is a single file and cannot hold those keys. Switching this
  # block to backend "local" {} is only useful for a one-off look at one key.
  # Run terraform init -reconfigure after changing the backend, and do not commit that edit.
  backend "azurerm" {}
}
