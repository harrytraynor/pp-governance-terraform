# Only the attributes set here are sent. Provider 4.2.1 skips nulls, so an
# omitted setting is not forced to false. Destroy restores the values captured
# at create. It does not delete the tenant.
resource "powerplatform_tenant_settings" "this" {
  disable_environment_creation_by_non_admin_users       = var.disable_environment_creation_by_non_admin_users
  disable_trial_environment_creation_by_non_admin_users = var.disable_trial_environment_creation_by_non_admin_users
  disable_portals_creation_by_non_admin_users           = var.disable_portals_creation_by_non_admin_users

  power_platform = {
    governance = {
      disable_developer_environment_creation_by_non_admin_users = var.disable_developer_environment_creation_by_non_admin_users
      enable_default_environment_routing                        = var.enable_default_environment_routing
      environment_routing_all_makers                            = var.environment_routing_all_makers
      environment_routing_target_environment_group_id           = var.environment_routing_target_environment_group_id
      environment_routing_target_security_group_id              = var.environment_routing_target_security_group_id
    }
    power_apps = {
      disable_share_with_everyone              = var.disable_share_with_everyone
      disable_connection_sharing_with_everyone = var.disable_connection_sharing_with_everyone
    }
    licensing = {
      disable_billing_policy_creation_by_non_admin_users = var.disable_billing_policy_creation_by_non_admin_users
    }
  }
}
