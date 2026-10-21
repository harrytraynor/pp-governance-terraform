variable "name" {
  type        = string
  description = "Environment display name and security group display name."
}

variable "description" {
  type        = string
  description = "Why this environment exists. Stored on the environment and the security group."
}

variable "environment_type" {
  type        = string
  description = "Sandbox or Production. Developer is preview and is not used."

  validation {
    condition     = contains(["Sandbox", "Production"], var.environment_type)
    error_message = "environment_type must be Sandbox or Production."
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
  description = "Cost centre recorded on the environment description."
}

variable "owner" {
  type        = string
  description = "Accountable person. Recorded in config. Not looked up in Entra."
}

variable "tier" {
  type        = string
  description = "Tier name recorded on the environment description."
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

variable "member_object_ids" {
  type        = list(string)
  description = "Entra object ids added as members of the environment security group."
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
