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
#   SOFT_DELETE_DAYS                blob and container soft-delete retention, default 14
#   RBAC_WAIT_SECONDS               how long to retry while role assignments propagate, default 600
#
# Hardening: shared key (account key and SAS) access is disabled, so every
# client must use Entra ID. The azurerm backend needs use_azuread_auth = true.
# TLS 1.2 minimum, HTTPS only, no public blob access, blob versioning, and
# blob and container soft delete.
#
# The identity you are signed in as needs permission to create the account and
# the role assignments, and Azure requires that sign-in to use MFA. The script
# grants Storage Blob Data Contributor on the storage account, then creates the
# container with --auth-mode login as the signed-in user, so it also grants that
# role to USER_ASSIGNEE_OBJECT_ID when set. Rerunning it is safe. It deletes nothing.
set -euo pipefail

: "${AZURE_LOCATION:?}"
: "${TF_STATE_RESOURCE_GROUP:?}"
: "${TF_STATE_STORAGE_ACCOUNT:?}"
: "${TF_STATE_CONTAINER:?}"
: "${ASSIGNEE_OBJECT_ID:?}"
SOFT_DELETE_DAYS="${SOFT_DELETE_DAYS:-14}"
RBAC_WAIT_SECONDS="${RBAC_WAIT_SECONDS:-600}"

if ! [[ "${TF_STATE_STORAGE_ACCOUNT}" =~ ^[a-z0-9]{3,24}$ ]]; then
  echo "TF_STATE_STORAGE_ACCOUNT must be 3-24 lowercase letters and digits." >&2
  exit 1
fi

az group create \
  --name "${TF_STATE_RESOURCE_GROUP}" \
  --location "${AZURE_LOCATION}" \
  --output none

az storage account create \
  --name "${TF_STATE_STORAGE_ACCOUNT}" \
  --resource-group "${TF_STATE_RESOURCE_GROUP}" \
  --location "${AZURE_LOCATION}" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --https-only true \
  --allow-blob-public-access false \
  --allow-shared-key-access false \
  --output none

az storage account blob-service-properties update \
  --account-name "${TF_STATE_STORAGE_ACCOUNT}" \
  --resource-group "${TF_STATE_RESOURCE_GROUP}" \
  --enable-versioning true \
  --enable-delete-retention true \
  --delete-retention-days "${SOFT_DELETE_DAYS}" \
  --enable-container-delete-retention true \
  --container-delete-retention-days "${SOFT_DELETE_DAYS}" \
  --output none

scope="$(az storage account show \
  --name "${TF_STATE_STORAGE_ACCOUNT}" \
  --resource-group "${TF_STATE_RESOURCE_GROUP}" \
  --query id \
  --output tsv)"

assign_blob_contributor() {
  local object_id="$1" principal_type="$2" existing
  # Filter on principalId so the check needs no Graph lookup.
  existing="$(az role assignment list \
    --role "Storage Blob Data Contributor" \
    --scope "${scope}" \
    --query "length([?principalId=='${object_id}'])" \
    --output tsv)"
  if [[ "${existing}" != "0" ]]; then
    echo "Storage Blob Data Contributor already assigned to ${object_id}."
    return
  fi
  az role assignment create \
    --assignee-object-id "${object_id}" \
    --assignee-principal-type "${principal_type}" \
    --role "Storage Blob Data Contributor" \
    --scope "${scope}" \
    --output none
  echo "Assigned Storage Blob Data Contributor to ${object_id}."
}

assign_blob_contributor "${ASSIGNEE_OBJECT_ID}" ServicePrincipal
if [[ -n "${USER_ASSIGNEE_OBJECT_ID:-}" ]]; then
  assign_blob_contributor "${USER_ASSIGNEE_OBJECT_ID}" User
fi

# Data-plane create as the signed-in identity. Role assignments can take several
# minutes to reach the data plane, so retry until RBAC_WAIT_SECONDS.
deadline=$((SECONDS + RBAC_WAIT_SECONDS))
until az storage container create \
  --name "${TF_STATE_CONTAINER}" \
  --account-name "${TF_STATE_STORAGE_ACCOUNT}" \
  --auth-mode login \
  --output none 2>/tmp/bootstrap-container.err; do
  if ((SECONDS >= deadline)); then
    cat /tmp/bootstrap-container.err >&2
    echo "Container create still failing after ${RBAC_WAIT_SECONDS}s. Check that the signed-in identity has Storage Blob Data Contributor." >&2
    exit 1
  fi
  echo "Waiting for blob data role propagation..."
  sleep 20
done

echo "State backend is ready. backend.hcl:"
echo "resource_group_name  = \"${TF_STATE_RESOURCE_GROUP}\""
echo "storage_account_name = \"${TF_STATE_STORAGE_ACCOUNT}\""
echo "container_name       = \"${TF_STATE_CONTAINER}\""
echo "key                  = \"STACK.tfstate\""
echo "use_azuread_auth     = true"
