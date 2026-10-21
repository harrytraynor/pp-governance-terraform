variable "tenant_id" {
  type        = string
  description = "Entra tenant id. Omit it to use POWER_PLATFORM_TENANT_ID."
  default     = null
}

variable "client_id" {
  type        = string
  description = "Application (client) id. Omit it to use POWER_PLATFORM_CLIENT_ID. Never put a client secret in a variable file."
  default     = null
}

variable "use_oidc" {
  type        = bool
  description = "Authenticate with a GitHub or Azure DevOps federated credential."
  default     = false
}

variable "use_cli" {
  type        = bool
  description = "Authenticate with the Azure CLI. Use this for a local plan. Do not combine it with use_oidc."
  default     = false
}

variable "name_prefix" {
  type        = string
  description = "Short prefix for resource names."
  default     = "ppgov"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,20}$", var.name_prefix))
    error_message = "name_prefix must be 2-20 characters: lowercase letters, digits, and hyphens."
  }
}

variable "manage_default_environment_dlp" {
  type        = bool
  description = "Create a block-by-default data policy scoped only to the tenant's default environment. Leave false until you have read the plan."
  default     = false
}

variable "route_new_makers_to_sandbox" {
  type        = bool
  description = "Second tenant apply, after the groups stack. Read the sandbox environment group id from groups remote state and turn on default-environment routing for new makers. Stays off in a fresh clone. An explicit environment_routing_target_group_id is used instead of the remote state read when it is set."
  default     = false
}

variable "environment_routing_target_group_id" {
  type        = string
  description = "Sandbox environment group id. When set, default-environment routing is switched on and this id is used. Leave null to keep routing off, or set route_new_makers_to_sandbox and the backend variables to read the id from groups state. Apply the groups stack first."
  default     = null
}

variable "backend_resource_group_name" {
  type        = string
  description = "Resource group of the Terraform state storage account. Used only when route_new_makers_to_sandbox reads groups state."
  default     = null
}

variable "backend_storage_account_name" {
  type        = string
  description = "Storage account of the Terraform state. Used only when route_new_makers_to_sandbox reads groups state."
  default     = null
}

variable "backend_container_name" {
  type        = string
  description = "Blob container of the Terraform state. Used only when route_new_makers_to_sandbox reads groups state."
  default     = null
}

variable "environment_routing_all_makers" {
  type        = bool
  description = "Used only when routing is on. False routes new makers. True routes every maker."
  default     = false
}

variable "environment_routing_target_security_group_id" {
  type        = string
  description = "Optional security group whose members are routed. Null leaves the current tenant value."
  default     = null
}
