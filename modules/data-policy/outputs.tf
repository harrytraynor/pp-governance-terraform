output "policy_id" {
  description = "Data policy id, or null when the policy is not created."
  value       = try(powerplatform_data_loss_prevention_policy.this[0].id, null)
}
