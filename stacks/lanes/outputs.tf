output "dev_environment_ids" {
  description = "Lane name to dev environment id."
  value       = { for name, env in module.dev : name => env.environment_id }
}

output "dev_environment_urls" {
  description = "Lane name to dev Dataverse URL."
  value       = { for name, env in module.dev : name => env.environment_url }
}

output "dev_security_group_ids" {
  description = "Lane name to dev security group object id. Null for a Developer lane, which has no lane group."
  value       = { for name, env in module.dev : name => env.security_group_object_id }
}

output "shared_test_environment_ids" {
  description = "Tier name to shared test environment id."
  value       = { for name, env in module.shared_test : name => env.environment_id }
}

output "shared_prod_environment_ids" {
  description = "Tier name to shared production environment id."
  value       = { for name, env in module.shared_prod : name => env.environment_id }
}

output "dedicated_test_environment_ids" {
  description = "Lane name to dedicated test environment id."
  value       = { for name, env in module.dedicated_test : name => env.environment_id }
}

output "dedicated_prod_environment_ids" {
  description = "Lane name to dedicated production environment id."
  value       = { for name, env in module.dedicated_prod : name => env.environment_id }
}

output "data_policy_ids" {
  description = "Tier name to data policy id."
  value       = { for name, policy in module.dlp : name => policy.policy_id }
}
