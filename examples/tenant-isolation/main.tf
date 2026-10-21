# Cross-tenant isolation, kept out of stacks/tenant.
# Provider 4.2.1 fails terraform validate when allowed_tenants is unknown,
# so this root cannot sit behind a count of zero in the tenant stack.
#
# The defaults below are known values: policy disabled, nobody on the allow list.
# Applying them starts managing the tenant's isolation policy. Read the plan.

provider "powerplatform" {
  tenant_id = var.tenant_id
  client_id = var.client_id
  use_oidc  = var.use_oidc
  use_cli   = var.use_cli
}

resource "powerplatform_tenant_isolation_policy" "this" {
  # Literals, not variables. Provider 4.2.1 fails terraform validate when
  # allowed_tenants is unknown, and validate does not apply variable defaults.
  # Edit these two arguments, then plan, when you intend to manage isolation.
  is_disabled = true
  allowed_tenants = [
    # {
    #   tenant_id = "11111111-1111-1111-1111-111111111111"
    #   inbound   = true
    #   outbound  = false
    # },
  ]
}
