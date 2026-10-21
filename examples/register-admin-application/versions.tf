terraform {
  required_version = ">= 1.6.0"

  required_providers {
    powerplatform = {
      source  = "microsoft/power-platform"
      version = "4.2.1"
    }
  }

  # One-shot local state. The service principal cannot register itself.
  backend "local" {}
}
