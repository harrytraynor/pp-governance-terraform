variable "name_label" {
  type        = string
  description = "Lane name, or all-lanes for a shared fan-in environment. Slugified with the cost centre and stage into the display name."

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9 ._-]{0,40}$", trimspace(var.name_label)))
    error_message = "name_label is required. Use letters, digits, spaces, dots, underscores, or hyphens."
  }
}

variable "stage" {
  type        = string
  description = "dev, test, or prod. The last segment of the display name."

  validation {
    condition     = contains(["dev", "test", "prod"], var.stage)
    error_message = "stage must be dev, test, or prod."
  }
}

variable "description" {
  type        = string
  description = "Why this environment exists. Stored on the environment and the security group."
}

variable "environment_type" {
  type        = string
  description = "Sandbox, Production, or Developer. Developer is preview, needs owner_id, and uses no tenant Dataverse database capacity."

  validation {
    condition     = contains(["Sandbox", "Production", "Developer"], var.environment_type)
    error_message = "environment_type must be Sandbox, Production, or Developer."
  }
}

variable "owner_id" {
  type        = string
  description = "Entra user object id that owns a Developer environment. Required when environment_type is Developer, ignored otherwise."
  default     = null

  validation {
    condition     = var.owner_id == null || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.owner_id))
    error_message = "owner_id must be an Entra user object id GUID."
  }
}

variable "cadence" {
  type        = string
  description = "Frequent or Moderate. Null leaves the platform default."
  default     = null
}

variable "location" {
  type        = string
  description = "Power Platform geography, for example europe or unitedkingdom. Mutually exclusive with macro_region."
  default     = null
}

variable "macro_region" {
  type        = string
  description = "Macro region, for example eu-efta, when the tenant rejects location. Mutually exclusive with location."
  default     = null
}

variable "language_code" {
  type        = number
  description = "Dataverse language LCID."
  default     = 1033
}

variable "currency_code" {
  type        = string
  description = "Dataverse currency code. It must be enabled in the tenant."
  default     = "GBP"
}

variable "environment_group_id" {
  type        = string
  description = "Group to create the environment in. Null means the environment stays outside every group."
  default     = null
}

variable "cost_centre" {
  type        = string
  description = "Cost centre. First segment of the environment display name, after it is trimmed, lowercased, and slugified. Blank is rejected. Lane files use CC-0000, which becomes cc-0000. Shared environments use shared."

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9 ._-]{0,40}$", trimspace(var.cost_centre)))
    error_message = "cost_centre is required. Trimmed, it must start with a letter or digit and use only letters, digits, spaces, dots, underscores, or hyphens. Example: CC-0000."
  }
}

variable "owner" {
  type        = string
  description = "Accountable person. Recorded in config. Not looked up in Entra."
}

variable "tier" {
  type        = string
  description = "Tier name. Recorded for group membership and release shape. Not part of the display name."

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9 ._-]{0,40}$", trimspace(var.tier)))
    error_message = "tier is required."
  }
}

variable "pipeline_application_id" {
  type        = string
  description = "Application (client) id of the service principal added as a Dataverse application user."

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.pipeline_application_id))
    error_message = "pipeline_application_id must be an application (client) id GUID."
  }
}

variable "security_role_name" {
  type        = string
  description = "Dataverse security role assigned to the pipeline application user."
  default     = "System Administrator"
}

variable "manage_security_role_assignment" {
  type        = bool
  description = "Create the security role assignment for the pipeline application user. Set false when Dataverse has already granted that role, for example because the pipeline application created the environment."
  default     = true
}

variable "member_object_ids" {
  type        = list(string)
  description = "Entra object ids added as members of the lane security group. Ignored for a Developer environment, which has no lane group."
  default     = []
}

variable "owner_object_ids" {
  type        = list(string)
  description = "Extra Entra object ids added as owners. The authenticated principal is always an owner."
  default     = []
}

variable "manage_with_managed_environment" {
  type        = bool
  description = "Apply powerplatform_managed_environment. Must stay false when environment_group_id is set."
  default     = false
}

variable "managed_environment" {
  type = object({
    is_usage_insights_disabled = bool
    is_group_sharing_disabled  = bool
    limit_sharing_mode         = string
    max_limit_user_sharing     = number
    solution_checker_mode      = string
    suppress_validation_emails = bool
  })
  description = "Managed environment settings for an environment that is deliberately outside a group."
  default     = null
}
