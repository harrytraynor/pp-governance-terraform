output "environment_group_ids" {
  description = "Map of tier name to environment group id. The lanes stack reads this."
  value       = { for _, group in module.group : group.tier_name => group.group_id }
}

output "rule_set_ids" {
  description = "Map of tier name to environment group rule set id."
  value       = { for _, group in module.group : group.tier_name => group.rule_set_id }
}
