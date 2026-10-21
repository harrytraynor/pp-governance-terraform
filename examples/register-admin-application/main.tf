# Run this once, signed in as a person who is already a Power Platform admin.
# Provider docs: a service principal cannot register itself.
#
#   az login
#   terraform init
#   terraform apply -var='application_client_id=YOUR-APP-CLIENT-ID'

provider "powerplatform" {
  use_cli = true
}

variable "application_client_id" {
  type        = string
  description = "Application (client) id of the service principal to register as a Power Platform admin management application."

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.application_client_id))
    error_message = "application_client_id must be an application (client) id GUID."
  }
}

resource "powerplatform_admin_management_application" "pipeline" {
  id = var.application_client_id
}
