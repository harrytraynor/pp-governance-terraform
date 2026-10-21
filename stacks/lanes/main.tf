provider "powerplatform" {
  tenant_id = var.tenant_id
  client_id = var.client_id
  use_oidc  = var.use_oidc
  use_cli   = var.use_cli
}

provider "azuread" {
  tenant_id = var.tenant_id
  client_id = var.client_id
  use_oidc  = var.use_oidc
  use_cli   = var.use_cli
}

data "azuread_client_config" "caller" {}

locals {
  tier_files = fileset("${path.root}/../../tiers", "*.yaml")
  lane_files = fileset("${path.root}/../../lanes", "*.yaml")

  lanes = {
    for filename in local.lane_files :
    yamldecode(file("${path.root}/../../lanes/${filename}")).lane => yamldecode(file("${path.root}/../../lanes/${filename}"))
  }

  backend_configured = (
    var.backend_storage_account_name != null && var.backend_storage_account_name != "" &&
    var.backend_resource_group_name != null && var.backend_resource_group_name != "" &&
    var.backend_container_name != null && var.backend_container_name != ""
  )
}

resource "terraform_data" "auth_mode" {
  lifecycle {
    precondition {
      condition     = !(var.use_oidc && var.use_cli)
      error_message = "Set only one of use_oidc or use_cli."
    }
    precondition {
      condition     = (var.location != null && var.location != "" && (var.macro_region == null || var.macro_region == "")) || (var.macro_region != null && var.macro_region != "" && (var.location == null || var.location == ""))
      error_message = "Set exactly one of location or macro_region."
    }
  }
}

module "tier" {
  source   = "../../modules/tier-config"
  for_each = local.tier_files

  tier = yamldecode(file("${path.root}/../../tiers/${each.value}"))
}

data "terraform_remote_state" "groups" {
  count   = var.group_ids == null && local.backend_configured ? 1 : 0
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
  tier_by_name = {
    for _, tier in module.tier : tier.name => tier
  }

  group_ids = var.group_ids != null ? var.group_ids : (
    length(data.terraform_remote_state.groups) == 1 ? data.terraform_remote_state.groups[0].outputs.environment_group_ids : {}
  )

  # Optional lane keys. A lane without them keeps the original Sandbox dev environment.
  dev_environment_types = {
    for name, lane in local.lanes : name => coalesce(try(lane.dev_environment_type, null), "Sandbox")
  }
  dev_environment_owner_ids = {
    for name, lane in local.lanes : name => try(lane.dev_environment_owner_object_id, null)
  }

  grouped_lanes = {
    for name, lane in local.lanes : name => lane
    if !lane.outside_group
  }

  lane_tiers = toset([for lane in local.lanes : lane.tier])

  shared_tiers = toset([
    for name in toset([for lane in local.grouped_lanes : lane.tier]) : name
    if var.create_release_stages && local.tier_by_name[name].fan_in && !local.tier_by_name[name].dedicated_prod
  ])

  dedicated_lanes = {
    for name, lane in local.grouped_lanes : name => lane
    if var.create_release_stages && local.tier_by_name[lane.tier].dedicated_prod
  }

  # The environment creator already holds System Administrator. Declaring the
  # same grant again fails with "already assigned".
  manage_pipeline_role = var.manage_pipeline_security_role != null ? var.manage_pipeline_security_role : !(
    lower(var.pipeline_application_id) == lower(data.azuread_client_config.caller.client_id) &&
    var.security_role_name == "System Administrator"
  )

  extra_members = var.pipeline_security_group_object_id != null && var.pipeline_security_group_object_id != "" ? [var.pipeline_security_group_object_id] : []
}

resource "terraform_data" "lane_rules" {
  for_each = local.lanes

  lifecycle {
    precondition {
      condition     = contains(keys(local.tier_by_name), each.value.tier)
      error_message = "Lane ${each.key} references tier ${each.value.tier}, which has no file in tiers/."
    }
    precondition {
      condition     = each.value.tier != "exception" || try(each.value.exception_expires_on, null) != null
      error_message = "Lane ${each.key} uses the exception tier and must set exception_expires_on (YYYY-MM-DD)."
    }
    precondition {
      condition     = contains(["Sandbox", "Developer"], local.dev_environment_types[each.key])
      error_message = "Lane ${each.key} sets dev_environment_type to ${local.dev_environment_types[each.key]}. Use Sandbox or Developer."
    }
    precondition {
      condition     = local.dev_environment_types[each.key] != "Developer" || local.dev_environment_owner_ids[each.key] != null
      error_message = "Lane ${each.key} uses a Developer dev environment and must set dev_environment_owner_object_id to an Entra user object id."
    }
    precondition {
      condition     = !each.value.outside_group || local.tier_by_name[each.value.tier].ungrouped_managed_environment_json != ""
      error_message = "Lane ${each.key} is outside a group, and tier ${each.value.tier} has no ungrouped_managed_environment block."
    }
    precondition {
      condition     = each.value.outside_group || contains(keys(local.group_ids), each.value.tier)
      error_message = "Lane ${each.key} needs the environment group id for tier ${each.value.tier}. Apply stacks/groups, then set group_ids or the backend_* variables."
    }
    precondition {
      condition     = var.group_ids != null || local.backend_configured || alltrue([for lane in local.lanes : lane.outside_group])
      error_message = "Set group_ids (local groups state) or backend_resource_group_name, backend_storage_account_name, and backend_container_name (remote groups state)."
    }
  }
}

module "dev" {
  source   = "../../modules/lane"
  for_each = local.lanes

  name                            = "${var.name_prefix}-${each.key}-dev"
  description                     = "${var.name_prefix}-${each.key}-dev. Cost centre ${each.value.cost_centre}. Owner ${each.value.owner}. Tier ${each.value.tier}. Dev mode ${each.value.dev_mode}. Governed by Terraform."
  environment_type                = local.dev_environment_types[each.key]
  owner_id                        = local.dev_environment_owner_ids[each.key]
  cadence                         = "Frequent"
  location                        = var.location == null || var.location == "" ? null : var.location
  macro_region                    = var.macro_region == null || var.macro_region == "" ? null : var.macro_region
  language_code                   = var.language_code
  currency_code                   = var.currency_code
  cost_centre                     = each.value.cost_centre
  owner                           = each.value.owner
  tier                            = each.value.tier
  pipeline_application_id         = var.pipeline_application_id
  security_role_name              = var.security_role_name
  manage_security_role_assignment = local.manage_pipeline_role
  member_object_ids               = distinct(concat(each.value.member_object_ids, local.extra_members))
  owner_object_ids                = var.security_group_owner_object_ids
  environment_group_id            = each.value.outside_group ? null : try(local.group_ids[each.value.tier], null)
  manage_with_managed_environment = each.value.outside_group
  managed_environment = (
    each.value.outside_group && local.tier_by_name[each.value.tier].ungrouped_managed_environment_json != ""
  ) ? jsondecode(local.tier_by_name[each.value.tier].ungrouped_managed_environment_json) : null
}

module "shared_test" {
  source   = "../../modules/lane"
  for_each = local.shared_tiers

  name                            = "${var.name_prefix}-shared-${each.key}-test"
  description                     = "Shared test for tier ${each.key}. Fan-in target. Governed by Terraform."
  environment_type                = "Sandbox"
  cadence                         = "Moderate"
  location                        = var.location == null || var.location == "" ? null : var.location
  macro_region                    = var.macro_region == null || var.macro_region == "" ? null : var.macro_region
  language_code                   = var.language_code
  currency_code                   = var.currency_code
  cost_centre                     = "shared"
  owner                           = "platform"
  tier                            = each.key
  pipeline_application_id         = var.pipeline_application_id
  security_role_name              = var.security_role_name
  manage_security_role_assignment = local.manage_pipeline_role
  member_object_ids               = local.extra_members
  owner_object_ids                = var.security_group_owner_object_ids
  environment_group_id            = local.group_ids[each.key]
}

module "shared_prod" {
  source   = "../../modules/lane"
  for_each = local.shared_tiers

  name                            = "${var.name_prefix}-shared-${each.key}-prod"
  description                     = "Shared production for tier ${each.key}. Fan-in target. Governed by Terraform."
  environment_type                = "Production"
  cadence                         = "Moderate"
  location                        = var.location == null || var.location == "" ? null : var.location
  macro_region                    = var.macro_region == null || var.macro_region == "" ? null : var.macro_region
  language_code                   = var.language_code
  currency_code                   = var.currency_code
  cost_centre                     = "shared"
  owner                           = "platform"
  tier                            = each.key
  pipeline_application_id         = var.pipeline_application_id
  security_role_name              = var.security_role_name
  manage_security_role_assignment = local.manage_pipeline_role
  member_object_ids               = local.extra_members
  owner_object_ids                = var.security_group_owner_object_ids
  environment_group_id            = local.group_ids[each.key]
}

module "dedicated_test" {
  source   = "../../modules/lane"
  for_each = local.dedicated_lanes

  name                            = "${var.name_prefix}-${each.key}-test"
  description                     = "${var.name_prefix}-${each.key}-test. Cost centre ${each.value.cost_centre}. Owner ${each.value.owner}. Tier ${each.value.tier}. Governed by Terraform."
  environment_type                = "Sandbox"
  cadence                         = "Moderate"
  location                        = var.location == null || var.location == "" ? null : var.location
  macro_region                    = var.macro_region == null || var.macro_region == "" ? null : var.macro_region
  language_code                   = var.language_code
  currency_code                   = var.currency_code
  cost_centre                     = each.value.cost_centre
  owner                           = each.value.owner
  tier                            = each.value.tier
  pipeline_application_id         = var.pipeline_application_id
  security_role_name              = var.security_role_name
  manage_security_role_assignment = local.manage_pipeline_role
  member_object_ids               = distinct(concat(each.value.member_object_ids, local.extra_members))
  owner_object_ids                = var.security_group_owner_object_ids
  environment_group_id            = local.group_ids[each.value.tier]
}

module "dedicated_prod" {
  source   = "../../modules/lane"
  for_each = local.dedicated_lanes

  name                            = "${var.name_prefix}-${each.key}-prod"
  description                     = "${var.name_prefix}-${each.key}-prod. Cost centre ${each.value.cost_centre}. Owner ${each.value.owner}. Tier ${each.value.tier}. Governed by Terraform."
  environment_type                = "Production"
  cadence                         = "Moderate"
  location                        = var.location == null || var.location == "" ? null : var.location
  macro_region                    = var.macro_region == null || var.macro_region == "" ? null : var.macro_region
  language_code                   = var.language_code
  currency_code                   = var.currency_code
  cost_centre                     = each.value.cost_centre
  owner                           = each.value.owner
  tier                            = each.value.tier
  pipeline_application_id         = var.pipeline_application_id
  security_role_name              = var.security_role_name
  manage_security_role_assignment = local.manage_pipeline_role
  member_object_ids               = distinct(concat(each.value.member_object_ids, local.extra_members))
  owner_object_ids                = var.security_group_owner_object_ids
  environment_group_id            = local.group_ids[each.value.tier]
}

# Personal developer environments created by routing are not resources in this
# state. The next lanes apply adds every environment currently in the Sandbox
# group to that tier's data policy. Provider 4.2.1 scopes a policy to environment
# ids, not to a group, so a brand-new routed environment waits for this apply.
data "powerplatform_environments" "catalogue" {
  count = try(local.group_ids["sandbox"], "") != "" ? 1 : 0
}

locals {
  sandbox_group_environment_ids = length(data.powerplatform_environments.catalogue) == 0 ? [] : [
    for env in data.powerplatform_environments.catalogue[0].environments : env.id
    if env.environment_group_id == local.group_ids["sandbox"]
  ]

  dlp_tiers = setunion(
    local.lane_tiers,
    length(local.sandbox_group_environment_ids) > 0 ? toset(["sandbox"]) : toset([]),
  )

  environment_ids_by_tier = {
    for tier_name in local.dlp_tiers : tier_name => distinct(concat(
      contains(local.lane_tiers, tier_name) ? concat(
        [for name, env in module.dev : env.environment_id if local.lanes[name].tier == tier_name],
        [for name, env in module.shared_test : env.environment_id if name == tier_name],
        [for name, env in module.shared_prod : env.environment_id if name == tier_name],
        [for name, env in module.dedicated_test : env.environment_id if local.lanes[name].tier == tier_name],
        [for name, env in module.dedicated_prod : env.environment_id if local.lanes[name].tier == tier_name],
      ) : [],
      tier_name == "sandbox" ? local.sandbox_group_environment_ids : [],
    ))
  }
}

module "dlp" {
  source   = "../../modules/data-policy"
  for_each = local.dlp_tiers

  create                       = length(local.environment_ids_by_tier[each.key]) > 0
  display_name                 = "${var.name_prefix}-tier-${each.key}"
  environment_ids              = local.environment_ids_by_tier[each.key]
  business_connector_ids       = local.tier_by_name[each.key].business_connector_ids
  custom_connectors_data_group = local.tier_by_name[each.key].custom_connectors_data_group
}
