output "display_name" {
  description = "Environment and security group display name: slugified cost centre, lane, then stage."
  value       = local.display_name
}

output "environment_id" {
  description = "Environment id."
  value       = powerplatform_environment.this.id
}

output "environment_url" {
  description = "Dataverse URL."
  value       = powerplatform_environment.this.dataverse.url
}

output "security_group_object_id" {
  description = "Entra object id of the environment security group."
  value       = azuread_group.this.object_id
}

output "application_user_id" {
  description = "Dataverse application user id."
  value       = powerplatform_application_user.pipeline.id
}

output "tier" {
  description = "Tier name passed in by the caller."
  value       = var.tier
}
