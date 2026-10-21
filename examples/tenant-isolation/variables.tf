variable "tenant_id" {
  type        = string
  description = "Entra tenant id. Omit it to use POWER_PLATFORM_TENANT_ID."
  default     = null
}

variable "client_id" {
  type        = string
  description = "Application (client) id. Omit it to use POWER_PLATFORM_CLIENT_ID."
  default     = null
}

variable "use_oidc" {
  type        = bool
  description = "Authenticate with a federated credential."
  default     = false
}

variable "use_cli" {
  type        = bool
  description = "Authenticate with the Azure CLI."
  default     = true
}
