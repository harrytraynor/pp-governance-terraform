variable "create" {
  type        = bool
  description = "Create the policy. When false, no connector catalogue call is made."
}

variable "display_name" {
  type        = string
  description = "Data policy display name."
}

variable "environment_ids" {
  type        = list(string)
  description = "Environments the policy applies to. The policy uses OnlyEnvironments."
  default     = []
}

variable "business_connector_ids" {
  type        = list(string)
  description = "Full connector ids for the business data group. Unblockable connectors are placed in non-business even if they are listed here."
  default     = []
}

variable "custom_connectors_data_group" {
  type        = string
  description = "Data group for custom connectors that do not match a more specific pattern. One of Business, NonBusiness, Blocked, Ignore."
  default     = "Blocked"

  validation {
    condition     = contains(["Business", "NonBusiness", "Blocked", "Ignore"], var.custom_connectors_data_group)
    error_message = "custom_connectors_data_group must be Business, NonBusiness, Blocked, or Ignore."
  }
}
