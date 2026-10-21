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

variable "manage_tenant_isolation" {
  type        = bool
  description = "Manage the tenant isolation policy. Leave false until you intend to change cross-tenant connections."
  default     = false
}

variable "tenant_isolation_disabled" {
  type        = bool
  description = "When isolation is managed, true stores the policy in a disabled state."
  default     = true
}

variable "tenant_isolation_allowed_tenants" {
  type = list(object({
    tenant_id = string
    inbound   = bool
    outbound  = bool
  }))
  description = "Tenants allowed through isolation. Ignored unless manage_tenant_isolation is true."
  default     = []
}

variable "environment_routing_target_group_id" {
  type        = string
  description = "Sandbox (or other) environment group id. When set, default-environment routing is switched on and new makers are sent there. Apply the groups stack first."
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
