#!/usr/bin/env bash
# Create the Azure Storage account used as the Terraform backend.
# This is separate from the Power Platform stacks: the stacks cannot create
# the account they store their own state in.
#
# Required environment variables:
#   AZURE_LOCATION                  for example westeurope
#   TF_STATE_RESOURCE_GROUP
#   TF_STATE_STORAGE_ACCOUNT        3-24 lowercase letters and digits, globally unique
#   TF_STATE_CONTAINER              for example tfstate
#   ASSIGNEE_OBJECT_ID              enterprise application object id that will read and write state
#
# Optional:
#   USER_ASSIGNEE_OBJECT_ID         Entra user object id that also gets Storage Blob Data
#                                   Contributor, for local runs with the Azure CLI
#
# The identity you are signed in as needs permission to create the account and
# the role assignment. The assignee needs Storage Blob Data Contributor, which
# is what the azurerm backend uses with OIDC.
set -euo pipefail

: "${AZURE_LOCATION:?}"
: "${TF_STATE_RESOURCE_GROUP:?}"
: "${TF_STATE_STORAGE_ACCOUNT:?}"
: "${TF_STATE_CONTAINER:?}"
: "${ASSIGNEE_OBJECT_ID:?}"

if ! [[ "${TF_STATE_STORAGE_ACCOUNT}" =~ ^[a-z0-9]{3,24}$ ]]; then
  echo "TF_STATE_STORAGE_ACCOUNT must be 3-24 lowercase letters and digits." >&2
  exit 1
fi

az group create \
  --name "${TF_STATE_RESOURCE_GROUP}" \
  --location "${AZURE_LOCATION}"

az storage account create \
  --name "${TF_STATE_STORAGE_ACCOUNT}" \
  --resource-group "${TF_STATE_RESOURCE_GROUP}" \
  --location "${AZURE_LOCATION}" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false

# Management-plane create. "az storage container create --auth-mode login" needs a
# blob data role on the caller, which Owner and Contributor do not include.
az storage container-rm create \
  --name "${TF_STATE_CONTAINER}" \
  --storage-account "${TF_STATE_STORAGE_ACCOUNT}" \
  --resource-group "${TF_STATE_RESOURCE_GROUP}" \
  --public-access off

scope="$(az storage account show \
  --name "${TF_STATE_STORAGE_ACCOUNT}" \
  --resource-group "${TF_STATE_RESOURCE_GROUP}" \
  --query id \
  --output tsv)"

az role assignment create \
  --assignee-object-id "${ASSIGNEE_OBJECT_ID}" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "${scope}"

if [[ -n "${USER_ASSIGNEE_OBJECT_ID:-}" ]]; then
  az role assignment create \
    --assignee-object-id "${USER_ASSIGNEE_OBJECT_ID}" \
    --assignee-principal-type User \
    --role "Storage Blob Data Contributor" \
    --scope "${scope}"
fi

echo "State backend is ready."
echo "resource_group_name  = \"${TF_STATE_RESOURCE_GROUP}\""
echo "storage_account_name = \"${TF_STATE_STORAGE_ACCOUNT}\""
echo "container_name       = \"${TF_STATE_CONTAINER}\""
