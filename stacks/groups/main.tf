provider "powerplatform" {
  tenant_id = var.tenant_id
  client_id = var.client_id
  use_oidc  = var.use_oidc
  use_cli   = var.use_cli
}

locals {
  tier_files = fileset("${path.root}/../../tiers", "*.yaml")
}

resource "terraform_data" "auth_mode" {
  lifecycle {
    precondition {
      condition     = !(var.use_oidc && var.use_cli)
      error_message = "Set only one of use_oidc or use_cli. When both are false, the provider uses a client secret from POWER_PLATFORM_CLIENT_SECRET."
    }
  }
}

module "group" {
  source   = "../../modules/environment-group"
  for_each = local.tier_files

  tier = yamldecode(file("${path.root}/../../tiers/${each.value}"))
}
