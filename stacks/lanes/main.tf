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
  # ** includes lanes/customer-service.yaml and lanes/operations/field-operations.yaml.
  # The for_each key is the lane field, not the path, so moving a file does not
  # replace the environment. Two files with the same lane field fail here.
  lane_files = fileset("${path.root}/../../lanes", "**/*.yaml")

  all_lanes = {
    for filename in local.lane_files :
    yamldecode(file("${path.root}/../../lanes/${filename}")).lane => yamldecode(file("${path.root}/../../lanes/${filename}"))
  }

  # Same slug as modules/lane and scripts/lane_states.py.
  lane_cost_centre_slugs = {
    for name, lane in local.all_lanes :
    name => trim(replace(replace(replace(lower(trimspace(lane.cost_centre)), " ", "-"), "_", "-"), "/-+/", "-"), "-")
  }

  manage_shared = var.cost_centre == "shared"

  # One apply, one state. A cost centre run sees only its lanes. shared sees none
  # of them and instead manages fan-in environments and the tier data policies.
  lanes = local.manage_shared ? {} : {
    for name, lane in local.all_lanes : name => lane
    if local.lane_cost_centre_slugs[name] == var.cost_centre
  }

  # Slugs the shared state may read. "shared" is this stack's own key, not a
  # cost centre blob. CI passes the slugs whose blobs already exist.
  lane_state_slugs = var.lane_remote_state_slugs == null ? toset([
    for slug in values(local.lane_cost_centre_slugs) : slug
    if slug != "shared" && slug != ""
    ]) : toset([
    for slug in var.lane_remote_state_slugs : slug
    if contains(values(local.lane_cost_centre_slugs), slug) && slug != "shared" && slug != ""
  ])

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
    precondition {
      condition     = local.manage_shared || length(local.lanes) > 0
      error_message = "cost_centre ${var.cost_centre} matches no lane file. Refusing an empty plan, which would destroy the environments in this state. Init with key=lanes/${var.cost_centre}.tfstate and pass the matching cost_centre."
    }
    precondition {
      condition     = length(local.duplicate_display_names) == 0
      error_message = "Environment display names must stay unique per lane and stage. These collide: ${join(", ", local.duplicate_display_names)}. The name is <cost centre>-<lane>-<stage> and no longer includes the tier."
    }
    precondition {
      condition     = !local.manage_shared || length(local.all_lanes) == 0 || local.backend_configured
      error_message = "cost_centre shared reads lanes/<slug>.tfstate for data policy membership. Set backend_resource_group_name, backend_storage_account_name, and backend_container_name. A local backend cannot hold the split state keys."
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

# The shared state owns the tier data policies, so it reads each cost centre
# state for the environment ids those policies must list. Cost centre applies
# do not read each other, and they do not read this state.
data "terraform_remote_state" "lane_state" {
  for_each = local.manage_shared && local.backend_configured ? local.lane_state_slugs : toset([])
  backend  = "azurerm"

  config = {
    resource_group_name  = var.backend_resource_group_name
    storage_account_name = var.backend_storage_account_name
    container_name       = var.backend_container_name
    key                  = "lanes/${each.key}.tfstate"
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

  all_grouped_lanes = {
    for name, lane in local.all_lanes : name => lane
    if !lane.outside_group
  }

  lane_tiers = toset([for lane in local.lanes : lane.tier])

  # Fan-in tiers come from every lane file, and only the shared state creates them.
  shared_tiers = toset([
    for name in toset([for lane in local.all_grouped_lanes : lane.tier]) : name
    if local.manage_shared && var.create_release_stages && local.tier_by_name[name].fan_in && !local.tier_by_name[name].dedicated_prod
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

  # Added to a Sandbox or Production lane group. A Developer lane has no group,
  # so the dev module passes an empty member list and ignores this value.
  extra_members = var.pipeline_security_group_object_id != null && var.pipeline_security_group_object_id != "" ? [var.pipeline_security_group_object_id] : []

  # Names come from modules/lane. The tier is not part of the name, so two
  # fan-in tiers, or two lanes that slugify the same way, would collide.
  created_display_names = concat(
    [for _, env in module.dev : env.display_name],
    [for _, env in module.shared_test : env.display_name],
    [for _, env in module.shared_prod : env.display_name],
    [for _, env in module.dedicated_test : env.display_name],
    [for _, env in module.dedicated_prod : env.display_name],
  )
  duplicate_display_names = [
    for name in toset(local.created_display_names) : name
    if length([for candidate in local.created_display_names : candidate if candidate == name]) > 1
  ]
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
    precondition {
      condition     = length(local.duplicate_display_names) == 0
      error_message = "Environment display names must stay unique per lane and stage. These collide: ${join(", ", local.duplicate_display_names)}. The name is <cost centre>-<lane>-<stage> and no longer includes the tier."
    }
  }
}

module "dev" {
  source   = "../../modules/lane"
  for_each = local.lanes

  name_label                      = each.key
  stage                           = "dev"
  description                     = "Cost centre ${each.value.cost_centre}. Owner ${each.value.owner}. Tier ${each.value.tier}. Dev mode ${each.value.dev_mode}. Governed by Terraform."
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
  member_object_ids               = local.dev_environment_types[each.key] == "Developer" ? [] : distinct(concat(each.value.member_object_ids, local.extra_members))
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

  name_label                      = "all-lanes"
  stage                           = "test"
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

  name_label                      = "all-lanes"
  stage                           = "prod"
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

  name_label                      = each.key
  stage                           = "test"
  description                     = "Cost centre ${each.value.cost_centre}. Owner ${each.value.owner}. Tier ${each.value.tier}. Governed by Terraform."
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

  name_label                      = each.key
  stage                           = "prod"
  description                     = "Cost centre ${each.value.cost_centre}. Owner ${each.value.owner}. Tier ${each.value.tier}. Governed by Terraform."
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

# Data policy membership comes from environments Terraform manages.
# Do not list the tenant with powerplatform_environments. Provider 4.2.1 reads
# Dataverse /organizations for every environment in that list, including Default,
# and the pipeline service principal is not a user there (0x80072560).
# Only the shared state publishes the policies. It unions ids from each
# lanes/<cost-centre>.tfstate with the fan-in environments in this state.
locals {
  remote_policy_items = flatten([
    for _, remote in data.terraform_remote_state.lane_state : concat(
      [
        for name, id in try(remote.outputs.dev_environment_ids, {}) : {
          tier = local.all_lanes[name].tier
          id   = id
        } if contains(keys(local.all_lanes), name)
      ],
      [
        for name, id in try(remote.outputs.dedicated_test_environment_ids, {}) : {
          tier = local.all_lanes[name].tier
          id   = id
        } if contains(keys(local.all_lanes), name)
      ],
      [
        for name, id in try(remote.outputs.dedicated_prod_environment_ids, {}) : {
          tier = local.all_lanes[name].tier
          id   = id
        } if contains(keys(local.all_lanes), name)
      ],
    )
  ])

  local_policy_items = concat(
    [for name, env in module.dev : { tier = local.lanes[name].tier, id = env.environment_id }],
    [for name, env in module.dedicated_test : { tier = local.lanes[name].tier, id = env.environment_id }],
    [for name, env in module.dedicated_prod : { tier = local.lanes[name].tier, id = env.environment_id }],
    [for name, env in module.shared_test : { tier = name, id = env.environment_id }],
    [for name, env in module.shared_prod : { tier = name, id = env.environment_id }],
  )

  policy_items = concat(local.remote_policy_items, local.local_policy_items)

  # Keys come from the lane files. Policy ids can be unknown on the first
  # shared apply; for_each keys cannot.
  dlp_tiers = toset(local.manage_shared ? [for lane in local.all_lanes : lane.tier] : [])

  managed_environment_ids_by_tier = {
    for tier_name in local.dlp_tiers : tier_name => distinct([
      for item in local.policy_items : item.id if item.tier == tier_name
    ])
  }
}

module "dlp" {
  source   = "../../modules/data-policy"
  for_each = local.dlp_tiers

  create                       = length(local.managed_environment_ids_by_tier[each.key]) > 0
  display_name                 = "${var.name_prefix}-tier-${each.key}"
  environment_ids              = local.managed_environment_ids_by_tier[each.key]
  business_connector_ids       = local.tier_by_name[each.key].business_connector_ids
  custom_connectors_data_group = local.tier_by_name[each.key].custom_connectors_data_group
}
