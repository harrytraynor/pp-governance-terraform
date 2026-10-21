data "powerplatform_connectors" "all" {
  count = var.create ? 1 : 0
}

locals {
  catalogue = var.create ? data.powerplatform_connectors.all[0].connectors : []
  wanted    = toset(var.business_connector_ids)
  known     = toset([for connector in local.catalogue : connector.id])
  missing   = [for id in var.business_connector_ids : id if !contains(local.known, id)]

  # Unblockable connectors cannot be classified as business or blocked.
  business = [
    for connector in local.catalogue : connector
    if contains(local.wanted, connector.id) && connector.unblockable == false
  ]
  non_business = [
    for connector in local.catalogue : connector
    if connector.unblockable == true
  ]
  blocked = [
    for connector in local.catalogue : connector
    if connector.unblockable == false && !contains(local.wanted, connector.id)
  ]
}

resource "terraform_data" "known_connectors" {
  count = var.create ? 1 : 0

  lifecycle {
    precondition {
      condition     = length(local.missing) == 0
      error_message = "These business connector ids are not in the tenant catalogue: ${join(", ", local.missing)}"
    }
    precondition {
      condition     = length(var.environment_ids) > 0
      error_message = "Data policy ${var.display_name} needs at least one environment id."
    }
  }
}

resource "powerplatform_data_loss_prevention_policy" "this" {
  count = var.create ? 1 : 0

  display_name                      = var.display_name
  default_connectors_classification = "Blocked"
  environment_type                  = "OnlyEnvironments"
  environments                      = toset(var.environment_ids)

  business_connectors = toset([
    for connector in local.business : {
      id                           = connector.id
      default_action_rule_behavior = ""
      action_rules                 = []
      endpoint_rules               = []
    }
  ])

  non_business_connectors = toset([
    for connector in local.non_business : {
      id                           = connector.id
      default_action_rule_behavior = ""
      action_rules                 = []
      endpoint_rules               = []
    }
  ])

  blocked_connectors = toset([
    for connector in local.blocked : {
      id                           = connector.id
      default_action_rule_behavior = ""
      action_rules                 = []
      endpoint_rules               = []
    }
  ])

  custom_connectors_patterns = toset([
    {
      order            = 1
      host_url_pattern = "*"
      data_group       = var.custom_connectors_data_group
    }
  ])

  depends_on = [terraform_data.known_connectors]
}
