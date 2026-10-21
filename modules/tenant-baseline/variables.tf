variable "disable_environment_creation_by_non_admin_users" {
  type = bool
}

variable "disable_trial_environment_creation_by_non_admin_users" {
  type = bool
}

variable "disable_portals_creation_by_non_admin_users" {
  type = bool
}

variable "disable_developer_environment_creation_by_non_admin_users" {
  type = bool
}

variable "enable_default_environment_routing" {
  type = bool
}

variable "environment_routing_all_makers" {
  type        = bool
  default     = null
  nullable    = true
  description = "True routes all makers. False routes new makers. Null leaves the current value."
}

variable "environment_routing_target_environment_group_id" {
  type        = string
  default     = null
  nullable    = true
  description = "Environment group that receives personal developer environments created by routing."
}

variable "environment_routing_target_security_group_id" {
  type        = string
  default     = null
  nullable    = true
  description = "Security group allowed to be routed. The empty guid means every user. Null leaves the current value."
}

variable "disable_share_with_everyone" {
  type = bool
}

variable "disable_connection_sharing_with_everyone" {
  type = bool
}

variable "disable_billing_policy_creation_by_non_admin_users" {
  type = bool
}
