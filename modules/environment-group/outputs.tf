output "group_id" {
  description = "Environment group id."
  value       = powerplatform_environment_group.this.id
}

output "tier_name" {
  description = "Tier name."
  value       = var.tier.tier
}

output "rule_set_id" {
  description = "Environment group rule set id."
  value       = powerplatform_environment_group_rule_set.this.id
}
