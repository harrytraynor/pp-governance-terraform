locals {
  raw = try(var.tier.environment_group.rules, {})

  sharing  = try(local.raw.sharing_controls, null)
  checker  = try(local.raw.solution_checker_enforcement, null)
  backup   = try(local.raw.backup_retention, null)
  insights = try(local.raw.usage_insights, null)
  welcome  = try(local.raw.maker_welcome_content, null)
  ai_desc  = try(local.raw.ai_generated_descriptions, null)
  ai_gen   = try(local.raw.ai_generative_settings, null)
  acp_only = try(local.raw.advanced_connector_policies_only, null)
  acp      = try(local.raw.advanced_connector_policies, null)

  # Null nested attributes are left unset. The provider does not publish a rule
  # it was not given, and a later plan does not try to delete rules Terraform
  # does not manage (provider 4.2.1 adopts an existing rule set).
  rules = {
    sharing_controls = local.sharing == null ? null : {
      share_mode      = local.sharing.share_mode
      share_max_limit = local.sharing.share_mode == "no limit" ? null : local.sharing.share_max_limit
    }
    solution_checker_enforcement = local.checker == null ? null : {
      solution_checker_mode = local.checker.solution_checker_mode
      send_emails_enabled   = local.checker.send_emails_enabled
    }
    backup_retention = local.backup == null ? null : {
      period_in_days = local.backup.period_in_days
    }
    usage_insights = local.insights == null ? null : {
      insights_enabled = local.insights.insights_enabled
    }
    maker_welcome_content = local.welcome == null ? null : {
      maker_onboarding_url      = local.welcome.maker_onboarding_url
      maker_onboarding_markdown = local.welcome.maker_onboarding_markdown
    }
    ai_generated_descriptions = local.ai_desc == null ? null : {
      ai_description_enabled = local.ai_desc.ai_description_enabled
    }
    ai_generative_settings = local.ai_gen == null ? null : {
      bing_search_enabled              = local.ai_gen.bing_search_enabled
      move_data_across_regions_enabled = local.ai_gen.move_data_across_regions_enabled
    }
    advanced_connector_policies_only = local.acp_only == null ? null : {
      enabled = local.acp_only.enabled
    }
    advanced_connector_policies = local.acp == null ? null : {
      allowed_connectors = [
        for connector in local.acp.allowed_connectors : {
          connector_id    = connector.connector_id
          actions_mode    = connector.actions_mode
          allowed_actions = try(connector.allowed_actions, null)
        }
      ]
    }
  }
}

resource "powerplatform_environment_group" "this" {
  display_name = "Tier - ${title(var.tier.tier)}"
  description  = substr("Governed by Terraform. Do not edit rules in the admin centre. ${var.tier.description}", 0, 500)
}

resource "powerplatform_environment_group_rule_set" "this" {
  environment_group_id = powerplatform_environment_group.this.id
  rules                = local.rules
}
