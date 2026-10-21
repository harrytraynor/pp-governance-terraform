# Normalises one tier file into outputs with stable types.
# Tier files are allowed to differ (a null rule versus a nested object).
# Reading them through this module avoids a Terraform map whose element types do not match.

locals {
  ungrouped = try(var.tier.ungrouped_managed_environment, null)
}

resource "terraform_data" "tier" {
  input = var.tier.tier

  lifecycle {
    precondition {
      condition     = contains(["sandbox", "small", "medium", "large", "exception"], var.tier.tier)
      error_message = "Tier name ${var.tier.tier} is not one of sandbox, small, medium, large, exception."
    }
  }
}
