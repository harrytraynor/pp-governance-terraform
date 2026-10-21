variable "tenant_id" {
  type        = string
  description = "Entra tenant id. Omit it to use POWER_PLATFORM_TENANT_ID or ARM_TENANT_ID."
  default     = null
}

variable "client_id" {
  type        = string
  description = "Application (client) id used to authenticate. Omit it to use the provider environment variables."
  default     = null
}

variable "use_oidc" {
  type        = bool
  description = "Authenticate with a federated credential."
  default     = false
}

variable "use_cli" {
  type        = bool
  description = "Authenticate with the Azure CLI. Do not combine it with use_oidc."
  default     = false
}

variable "name_prefix" {
  type        = string
  description = "Short prefix for environment and group names."
  default     = "ppgov"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,20}$", var.name_prefix))
    error_message = "name_prefix must be 2-20 characters: lowercase letters, digits, and hyphens."
  }
}

variable "location" {
  type        = string
  description = "Power Platform geography, for example europe or unitedkingdom. Set null when macro_region is set."
  default     = null
}

variable "macro_region" {
  type        = string
  description = "Macro region, for example eu-efta, for tenants that reject location."
  default     = null
}

variable "language_code" {
  type        = number
  description = "Dataverse language LCID."
  default     = 1033
}

variable "currency_code" {
  type        = string
  description = "Dataverse currency code enabled in the tenant."
  default     = "GBP"
}

variable "pipeline_application_id" {
  type        = string
  description = "Application (client) id added as a Dataverse application user in every environment this stack creates."

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

variable "manage_pipeline_security_role" {
  type        = bool
  description = "Create the pipeline application user's security role assignment. Null decides automatically: false when pipeline_application_id is the identity running Terraform and security_role_name is System Administrator, because Dataverse already grants that role to the environment creator; true otherwise."
  default     = null
  nullable    = true
}

variable "pipeline_security_group_object_id" {
  type        = string
  description = "Optional enterprise-application object id added as a member of every environment security group. This is not the client id. Leave null unless Dataverse refuses the caller."
  default     = null
}

variable "security_group_owner_object_ids" {
  type        = list(string)
  description = "Extra Entra object ids added as owners of every environment security group."
  default     = []
}

variable "create_release_stages" {
  type        = bool
  description = "Also create test and production. False keeps the first apply to dev environments only."
  default     = false
}

variable "group_ids" {
  type        = map(string)
  description = "Tier name to environment group id. Set this when the groups stack uses a local backend. Leave null to read the groups remote state."
  default     = null
}

variable "backend_resource_group_name" {
  type        = string
  description = "Resource group of the Terraform state storage account. Required when group_ids is null."
  default     = null
}

variable "backend_storage_account_name" {
  type        = string
  description = "Storage account of the Terraform state. Required when group_ids is null."
  default     = null
}

variable "backend_container_name" {
  type        = string
  description = "Blob container of the Terraform state. Required when group_ids is null."
  default     = null
}
