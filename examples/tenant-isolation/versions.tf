terraform {
  required_version = ">= 1.6.0"

  required_providers {
    powerplatform = {
      source  = "microsoft/power-platform"
      version = "4.2.1"
    }
  }

  # Separate from stacks/tenant on purpose. Apply this only when you intend
  # to manage cross-tenant isolation. Local state keeps it out of CI.
  backend "local" {}
}
