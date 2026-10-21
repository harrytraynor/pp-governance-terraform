output "name" {
  description = "Tier name."
  value       = var.tier.tier
}

output "description" {
  description = "Human description from the tier file."
  value       = var.tier.description
}

output "fan_in" {
  description = "True when dev lanes share one test and one production environment."
  value       = var.tier.release.fan_in
}

output "dedicated_prod" {
  description = "True when each lane gets its own test and production environments."
  value       = var.tier.release.dedicated_prod
}

output "business_connector_ids" {
  description = "Connector ids placed in the business data group."
  value       = var.tier.dlp.business_connector_ids
}

output "custom_connectors_data_group" {
  description = "Data group for the catch-all custom connector pattern."
  value       = var.tier.dlp.custom_connectors_data_group
}

output "ungrouped_managed_environment_json" {
  description = "JSON for powerplatform_managed_environment, or an empty string when the tier has none."
  value       = local.ungrouped == null ? "" : jsonencode(local.ungrouped)
}
