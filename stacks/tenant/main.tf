provider "powerplatform" {
  tenant_id = var.tenant_id
  client_id = var.client_id
  use_oidc  = var.use_oidc
  use_cli   = var.use_cli
}

locals {
  baseline = yamldecode(file("${path.root}/../../tenant/baseline.yaml"))

  # An explicit id (tfvars or ENVIRONMENT_ROUTING_TARGET_GROUP_ID) wins.
  # Otherwise route_new_makers_to_sandbox reads groups state. Both stay off
  # until someone opts in, and the first tenant apply does not need the
  # groups stack to exist yet.
  explicit_routing_group_id = (
    var.environment_routing_target_group_id != null && var.environment_routing_target_group_id != ""
  ) ? var.environment_routing_target_group_id : null

  backend_configured = (
    var.backend_storage_account_name != null && var.backend_storage_account_name != "" &&
    var.backend_resource_group_name != null && var.backend_resource_group_name != "" &&
    var.backend_container_name != null && var.backend_container_name != ""
  )

  read_groups_state = var.route_new_makers_to_sandbox && local.explicit_routing_group_id == null && local.backend_configured
}

data "terraform_remote_state" "groups" {
  count   = local.read_groups_state ? 1 : 0
  backend = "azurerm"

  config = {
    resource_group_name  = var.backend_resource_group_name
    storage_account_name = var.backend_storage_account_name
    container_name       = var.backend_container_name
    key                  = "groups.tfstate"
    use_oidc             = var.use_oidc
    use_azuread_auth     = true
  }
}

locals {
  sandbox_group_from_state = local.read_groups_state ? try(data.terraform_remote_state.groups[0].outputs.environment_group_ids["sandbox"], null) : null
  routing_target_group_id  = local.explicit_routing_group_id != null ? local.explicit_routing_group_id : local.sandbox_group_from_state
  routing_enabled          = local.routing_target_group_id != null && local.routing_target_group_id != ""
}

resource "terraform_data" "auth_mode" {
  lifecycle {
    precondition {
      condition     = !(var.use_oidc && var.use_cli)
      error_message = "Set only one of use_oidc or use_cli. When both are false, the provider uses a client secret from POWER_PLATFORM_CLIENT_SECRET."
    }
    precondition {
      condition     = !var.route_new_makers_to_sandbox || local.routing_target_group_id != null
      error_message = "route_new_makers_to_sandbox did not find a sandbox group id. Apply the groups stack first, then set backend_resource_group_name, backend_storage_account_name, and backend_container_name so this stack can read groups.tfstate, or set environment_routing_target_group_id."
    }
  }
}

data "powerplatform_environments" "all" {
  count = var.manage_default_environment_dlp ? 1 : 0
}

locals {
  default_environment_ids = var.manage_default_environment_dlp ? [
    for env in data.powerplatform_environments.all[0].environments : env.id
    if env.environment_type == "Default"
  ] : []
}

module "baseline" {
  source = "../../modules/tenant-baseline"

  disable_environment_creation_by_non_admin_users       = local.baseline.disable_environment_creation_by_non_admin_users
  disable_trial_environment_creation_by_non_admin_users = local.baseline.disable_trial_environment_creation_by_non_admin_users
  disable_portals_creation_by_non_admin_users           = local.baseline.disable_portals_creation_by_non_admin_users
  disable_developer_environment_creation_by_non_admin_users = (
    local.routing_enabled ? false : local.baseline.disable_developer_environment_creation_by_non_admin_users
  )
  enable_default_environment_routing                 = local.routing_enabled ? true : local.baseline.enable_default_environment_routing
  environment_routing_all_makers                     = local.routing_enabled ? var.environment_routing_all_makers : null
  environment_routing_target_environment_group_id    = local.routing_enabled ? local.routing_target_group_id : null
  environment_routing_target_security_group_id       = local.routing_enabled ? var.environment_routing_target_security_group_id : null
  disable_share_with_everyone                        = local.baseline.disable_share_with_everyone
  disable_connection_sharing_with_everyone           = local.baseline.disable_connection_sharing_with_everyone
  disable_billing_policy_creation_by_non_admin_users = local.baseline.disable_billing_policy_creation_by_non_admin_users
}

module "default_environment_dlp" {
  source = "../../modules/data-policy"

  create                       = var.manage_default_environment_dlp
  display_name                 = "${var.name_prefix}-default-environment"
  environment_ids              = local.default_environment_ids
  business_connector_ids       = local.baseline.default_environment_dlp.business_connector_ids
  custom_connectors_data_group = local.baseline.default_environment_dlp.custom_connectors_data_group
}

resource "terraform_data" "default_environment_present" {
  count = var.manage_default_environment_dlp ? 1 : 0

  lifecycle {
    precondition {
      condition     = length(local.default_environment_ids) > 0
      error_message = "manage_default_environment_dlp is true, but no environment with environment_type Default was returned."
    }
  }
}
