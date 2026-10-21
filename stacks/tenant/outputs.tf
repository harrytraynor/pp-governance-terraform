output "tenant_settings_id" {
  description = "Tenant id recorded on the tenant settings resource."
  value       = module.baseline.tenant_settings_id
}

output "default_environment_dlp_id" {
  description = "Data policy id for the default environment, when that policy is managed."
  value       = module.default_environment_dlp.policy_id
}
