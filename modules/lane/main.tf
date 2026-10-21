data "azuread_client_config" "current" {}

locals {
  # <cost centre> - <lane> - <tier> - <stage>
  # Provider 4.2.1 does not force replacement when display_name changes.
  display_name = "${trimspace(var.cost_centre)} - ${trimspace(var.name_label)} - ${trimspace(var.tier)} - ${var.stage}"

  # Stable alias for new groups. Existing groups keep the alias already in state
  # (ignore_changes below). Changing mail_nickname would replace the Entra group.
  mail_nickname = substr(replace(lower("${trimspace(var.name_label)}-${trimspace(var.tier)}-${var.stage}"), "/[^a-z0-9]/", ""), 0, 64)

  # A count of zero still has to type-check. The placeholder is never sent.
  managed = var.managed_environment != null ? var.managed_environment : {
    is_usage_insights_disabled = true
    is_group_sharing_disabled  = true
    limit_sharing_mode         = "ExcludeSharingToSecurityGroups"
    max_limit_user_sharing     = 1
    solution_checker_mode      = "Block"
    suppress_validation_emails = true
  }
}

resource "azuread_group" "this" {
  display_name     = local.display_name
  description      = substr(var.description, 0, 1024)
  security_enabled = true
  mail_enabled     = false
  mail_nickname    = local.mail_nickname
  owners           = distinct(concat([data.azuread_client_config.current.object_id], var.owner_object_ids))

  lifecycle {
    ignore_changes = [mail_nickname]
  }
}

resource "azuread_group_member" "member" {
  for_each = toset(var.member_object_ids)

  group_object_id  = azuread_group.this.object_id
  member_object_id = each.value
}

resource "powerplatform_environment" "this" {
  display_name     = local.display_name
  description      = var.description
  location         = var.location
  macro_region     = var.macro_region
  environment_type = var.environment_type
  cadence          = var.cadence

  # Provider 4.2.1 requires owner_id for Developer and rejects it for every other type.
  owner_id = var.environment_type == "Developer" ? var.owner_id : null

  # Null is omitted. Do not send the empty guid: provider 4.2.1 used to treat
  # that as group membership and then managed-environment settings could never apply.
  environment_group_id = var.environment_group_id

  dataverse = {
    language_code = var.language_code
    currency_code = var.currency_code
    # Provider 4.2.1 rejects security_group_id together with owner_id, so a
    # Developer environment is not restricted to the lane group. The group is
    # still created, so switching the lane back to Sandbox keeps the same group.
    security_group_id = var.environment_type == "Developer" ? null : azuread_group.this.object_id
  }

  timeouts = {
    create = "90m"
    read   = "10m"
    update = "60m"
    delete = "60m"
  }

  # prevent_destroy must be a literal. Changing location or macro_region forces
  # replacement, and this stops a typo from planning that replacement.
  # owner_id is only used at create time for Developer environments; changing it
  # would force a replace, so later edits (or the placeholder in the public
  # example lanes) are ignored, and you transfer ownership in the admin centre
  # instead.
  # To destroy the environment, delete this lifecycle block, review the plan, and apply.
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [owner_id]

    precondition {
      condition     = (var.location != null && var.macro_region == null) || (var.location == null && var.macro_region != null)
      error_message = "Environment ${local.display_name} needs exactly one of location or macro_region."
    }
    precondition {
      condition     = var.environment_type != "Developer" || var.owner_id != null
      error_message = "Environment ${local.display_name} is a Developer environment and needs owner_id (an Entra user object id)."
    }
    precondition {
      condition     = var.manage_with_managed_environment ? var.environment_group_id == null && var.managed_environment != null : var.environment_group_id != null
      error_message = "Environment ${local.display_name} must either sit in a group or carry managed-environment settings, and never both. Group rules are the source of truth for grouped environments."
    }
  }
}

# Only for an environment that is deliberately outside a group.
# Provider docs: when an environment is in a group, managed environment settings
# do not apply, and plan returns a warning instead of a change.
resource "powerplatform_managed_environment" "this" {
  count = var.manage_with_managed_environment ? 1 : 0

  environment_id             = powerplatform_environment.this.id
  is_usage_insights_disabled = local.managed.is_usage_insights_disabled
  is_group_sharing_disabled  = local.managed.is_group_sharing_disabled
  limit_sharing_mode         = local.managed.limit_sharing_mode
  max_limit_user_sharing     = local.managed.max_limit_user_sharing
  solution_checker_mode      = local.managed.solution_checker_mode
  suppress_validation_emails = local.managed.suppress_validation_emails
}

resource "powerplatform_application_user" "pipeline" {
  environment_id = powerplatform_environment.this.id
  application_id = var.pipeline_application_id
}

# Dataverse grants System Administrator to the identity that creates the
# environment. When that identity is also the pipeline application, the grant
# already exists and the provider refuses to create it again, so the caller
# turns this off.
resource "powerplatform_security_role_assignment" "pipeline" {
  count = var.manage_security_role_assignment ? 1 : 0

  environment_id     = powerplatform_environment.this.id
  system_user_id     = powerplatform_application_user.pipeline.system_user_id
  security_role_name = var.security_role_name
}

moved {
  from = powerplatform_security_role_assignment.pipeline
  to   = powerplatform_security_role_assignment.pipeline[0]
}
