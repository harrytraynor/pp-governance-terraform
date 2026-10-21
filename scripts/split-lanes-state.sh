#!/usr/bin/env bash
# Split the single lanes.tfstate blob into lanes/<cost-centre>.tfstate and
# lanes/shared.tfstate. This moves state only. It does not refresh, plan, or
# apply, and it does not call Power Platform.
#
# Needs, for a real split: Azure login that can read and write the state
# container (Storage Blob Data Contributor), Terraform, and Python 3 with
# PyYAML. Does not need a Power Platform token or permission to change the
# tenant.
#
# Run it once, before the first apply that uses the split keys. From a
# checkout of the commit that introduces the split:
#
#   cd stacks/lanes
#   # backend.hcl must already point at the state account. For a laptop,
#   # use_oidc = false and use_azuread_auth = true, then az login.
#   ../../scripts/split-lanes-state.sh
#
# The script:
#   1. Pulls lanes.tfstate (or OLD_KEY) and uploads a copy to
#      lanes.tfstate.pre-split. The copy is the rollback.
#   2. Copies dev, dedicated, and lane_rules resources into
#      lanes/<slug>.tfstate. The example lanes land in lanes/cc-0000.tfstate.
#   3. Copies fan-in modules and tier data policies into lanes/shared.tfstate.
#   4. Copies tier markers and the auth marker into every new state so the
#      next plan does not recreate them.
#   5. Drops the tenant-wide environment catalogue data source. That is a
#      data source, not an environment.
#   6. Pushes the new blobs, then deletes the old lanes.tfstate blob so a
#      later apply cannot destroy resources out of the unsplit state.
#      prevent_destroy on the environments would stop that destroy, but the
#      old blob should not stay in use.
#
# --dry-run still reads the blob, prints the move plan, and does not upload
# or delete. --self-test splits a fixture state offline. --fixture FILE does
# the same for a state you already pulled.
#
# The script stops if it sees a resource address it does not recognise.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stack="${root}/stacks/lanes"
old_key="${OLD_KEY:-lanes.tfstate}"
mode="live"
dry_run=0
fixture=""

usage() {
  echo "Usage: scripts/split-lanes-state.sh [--dry-run | --self-test | --fixture FILE]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --self-test) mode="self-test" ;;
    --fixture)
      mode="fixture"
      shift
      fixture="${1:-}"
      if [ -z "${fixture}" ]; then
        usage
      fi
      ;;
    *) usage ;;
  esac
  shift
done

write_fixture() {
  local dest="$1"
  python3 - "${dest}" <<'PY'
import json
import re
import sys
import uuid

path = sys.argv[1]
addresses = [
    'module.dev["customer-service"].powerplatform_environment.this',
    'module.dev["field-operations"].azuread_group.this',
    'module.dedicated_prod["field-operations"].powerplatform_environment.this',
    'terraform_data.lane_rules["customer-service"]',
    'terraform_data.lane_rules["field-operations"]',
    'module.dlp["medium"].powerplatform_data_loss_prevention_policy.this[0]',
    'module.shared_test["medium"].powerplatform_environment.this',
    'module.tier["medium.yaml"].terraform_data.tier',
    "terraform_data.auth_mode",
    "data.azuread_client_config.caller",
    "data.terraform_remote_state.groups[0]",
    "data.powerplatform_environments.catalogue[0]",
    "terraform_data.display_names",
]
pattern = re.compile(
    r"^(?:(?P<data>data)\.)?"
    r"(?:module\.(?P<modname>[A-Za-z0-9_-]+)(?:\[\"(?P<modkey>(?:\\.|[^\"\\])*)\"\])?\.)?"
    r"(?P<type>[A-Za-z0-9_]+)\.(?P<name>[A-Za-z0-9_]+)"
    r"(?:\[(?P<index>(?:\"(?:\\.|[^\"\\])*\")|(?:[0-9]+))\])?$"
)
blocks = {}
order = []
for address in addresses:
    match = pattern.fullmatch(address)
    if not match:
        raise SystemExit(f"fixture address did not parse: {address}")
    module = None
    if match.group("modname"):
        module = f"module.{match.group('modname')}"
        if match.group("modkey") is not None:
            module += f'[\"{match.group("modkey")}\"]'
    index = match.group("index")
    index_key = None
    if index is not None:
        index_key = int(index) if index.isdigit() else json.loads(index)
    key = (module, "data" if match.group("data") else "managed", match.group("type"), match.group("name"))
    if key not in blocks:
        blocks[key] = []
        order.append(key)
    instance = {
        "schema_version": 0,
        "attributes": {"id": address},
        "sensitive_attributes": [],
    }
    if index_key is not None:
        instance["index_key"] = index_key
    blocks[key].append(instance)

resources = []
for key in order:
    module, mode_name, type_name, name = key
    resource = {
        "mode": mode_name,
        "type": type_name,
        "name": name,
        "provider": "provider[\"terraform.io/builtin/terraform\"]",
        "instances": blocks[key],
    }
    if module is not None:
        resource["module"] = module
    resources.append(resource)

document = {
    "version": 4,
    "terraform_version": "1.16.6",
    "serial": 5,
    "lineage": str(uuid.uuid4()),
    "outputs": {},
    "resources": resources,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle)
PY
}

split_state() {
  local source="$1"
  local work="$2"
  local addresses="${work}/addresses.txt"
  local classification

  terraform state list -state="${source}" > "${addresses}"
  classification="$(python3 "${root}/scripts/lane_states.py" --root "${root}" classify --addresses "${addresses}")"
  python3 - "${classification}" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
unknown = data["unknown"]
print("Targets:")
for name, addrs in sorted(data["targets"].items()):
    print(f"  lanes/{name}.tfstate: {len(addrs)} resource(s)")
print(f"Copied into every state: {len(data['copy'])}")
print(f"Dropped (not infrastructure): {len(data['drop'])}")
if unknown:
    print("Unrecognised addresses, no state was changed:", file=sys.stderr)
    for item in unknown:
        print(f"  {item}", file=sys.stderr)
    raise SystemExit(1)
PY

  local target dest
  while IFS= read -r target; do
    dest="${work}/${target}.tfstate"
    cp "${source}" "${dest}"
    mapfile -t remove < <(python3 - "${classification}" "${target}" "${addresses}" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
target = sys.argv[2]
addresses = [line.strip() for line in open(sys.argv[3], encoding="utf-8") if line.strip()]
owned = {}
for name, addrs in data["targets"].items():
    for addr in addrs:
        owned[addr] = name
drop = set(data["drop"])
for addr in addresses:
    if addr in drop or (addr in owned and owned[addr] != target):
        print(addr)
PY
)
    if [ "${#remove[@]}" -gt 0 ]; then
      local start=0
      while [ "${start}" -lt "${#remove[@]}" ]; do
        terraform state rm -lock=false -state="${dest}" "${remove[@]:start:20}" >/dev/null
        start=$((start + 20))
      done
    fi
    python3 - "${dest}" <<'PY'
import json, sys, uuid
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
data["lineage"] = str(uuid.uuid4())
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY
    echo "Built ${target}: $(terraform state list -state="${dest}" | wc -l | tr -d ' ') addresses"
  done < <(python3 -c 'import json,sys; print("\n".join(sorted(json.loads(sys.argv[1])["targets"])))' "${classification}")
}

assert_contains() {
  local file="$1"
  local needle="$2"
  if ! terraform state list -state="${file}" | grep -Fxq "${needle}"; then
    echo "self-test failed: ${file} is missing ${needle}" >&2
    terraform state list -state="${file}" >&2 || true
    exit 1
  fi
}

assert_absent() {
  local file="$1"
  local needle="$2"
  if terraform state list -state="${file}" | grep -Fxq "${needle}"; then
    echo "self-test failed: ${file} still has ${needle}" >&2
    exit 1
  fi
}

if [ "${mode}" = "self-test" ]; then
  work="$(mktemp -d)"
  trap 'rm -rf "${work}"' EXIT
  write_fixture "${work}/original.tfstate"
  split_state "${work}/original.tfstate" "${work}"
  cc="${work}/cc-0000.tfstate"
  shared="${work}/shared.tfstate"
  assert_contains "${cc}" 'module.dev["customer-service"].powerplatform_environment.this'
  assert_contains "${cc}" 'module.dev["field-operations"].azuread_group.this'
  assert_contains "${cc}" 'module.dedicated_prod["field-operations"].powerplatform_environment.this'
  assert_contains "${cc}" 'terraform_data.lane_rules["customer-service"]'
  assert_contains "${cc}" "terraform_data.auth_mode"
  assert_contains "${cc}" 'module.tier["medium.yaml"].terraform_data.tier'
  assert_absent "${cc}" 'module.dlp["medium"].powerplatform_data_loss_prevention_policy.this[0]'
  assert_absent "${cc}" "data.powerplatform_environments.catalogue[0]"
  assert_absent "${cc}" "terraform_data.display_names"
  assert_contains "${shared}" 'module.dlp["medium"].powerplatform_data_loss_prevention_policy.this[0]'
  assert_contains "${shared}" 'module.shared_test["medium"].powerplatform_environment.this'
  assert_contains "${shared}" "terraform_data.auth_mode"
  assert_absent "${shared}" 'module.dev["customer-service"].powerplatform_environment.this'
  assert_absent "${shared}" "data.powerplatform_environments.catalogue[0]"
  echo "split-lanes-state self-test passed"
  exit 0
fi

if [ "${mode}" = "fixture" ]; then
  if [ ! -f "${fixture}" ]; then
    echo "Fixture state not found: ${fixture}" >&2
    exit 1
  fi
  work="$(mktemp -d)"
  trap 'rm -rf "${work}"' EXIT
  echo "Splitting ${fixture} locally. Nothing is uploaded."
  split_state "${fixture}" "${work}"
  echo "Local split files are in ${work} until this process exits."
  echo "Dry inspection only. No blob was uploaded or deleted."
  # Keep the directory when the caller wants to inspect it.
  trap - EXIT
  echo "Left the split files in ${work}"
  exit 0
fi

if [ ! -f "${stack}/backend.hcl" ]; then
  echo "Missing ${stack}/backend.hcl. Copy backend.hcl.example and point it at the state account first." >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

export TF_IN_AUTOMATION=1
export TF_INPUT=0

init_key() {
  local key="$1"
  terraform -chdir="${stack}" init -input=false -reconfigure -backend-config=backend.hcl -backend-config="key=${key}" >/dev/null
}

echo "Pulling ${old_key}"
init_key "${old_key}"
terraform -chdir="${stack}" state pull > "${work}/original.tfstate"

python3 - "${work}/original.tfstate" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
resources = data.get("resources") or []
if not resources:
    raise SystemExit("The source state has no resources. Refusing to split an empty state.")
print(f"Source state serial {data.get('serial')} with {len(resources)} resource blocks")
PY

split_state "${work}/original.tfstate" "${work}"

if [ "${dry_run}" -eq 1 ]; then
  echo "Dry run only. No blob was uploaded or deleted."
  exit 0
fi

echo "Uploading backup blob lanes.tfstate.pre-split"
backup="${work}/lanes.tfstate.pre-split"
cp "${work}/original.tfstate" "${backup}"
python3 - "${backup}" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
data["serial"] = int(data.get("serial") or 0) + 1
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY
init_key "lanes.tfstate.pre-split"
terraform -chdir="${stack}" state push -force "${backup}"

echo "Pushing split states"
while IFS= read -r target; do
  key="lanes/${target}.tfstate"
  echo "  ${key}"
  init_key "${key}"
  terraform -chdir="${stack}" state push -force "${work}/${target}.tfstate"
done < <(python3 -c 'import json,sys; print("\n".join(sorted(json.loads(sys.argv[1])["targets"])))' "$(python3 "${root}/scripts/lane_states.py" --root "${root}" classify --addresses "${work}/addresses.txt")")

echo "Removing unsplit blob ${old_key}"
resource_group="$(awk -F'"' '/^[[:space:]]*resource_group_name[[:space:]]*=/{print $2; exit}' "${stack}/backend.hcl")"
storage_account="$(awk -F'"' '/^[[:space:]]*storage_account_name[[:space:]]*=/{print $2; exit}' "${stack}/backend.hcl")"
container="$(awk -F'"' '/^[[:space:]]*container_name[[:space:]]*=/{print $2; exit}' "${stack}/backend.hcl")"
if [ -z "${resource_group}" ] || [ -z "${storage_account}" ] || [ -z "${container}" ]; then
  echo "Could not read the storage account from backend.hcl. The new states are uploaded. Delete blob ${old_key} yourself after you confirm lanes.tfstate.pre-split." >&2
  exit 1
fi
az storage blob delete \
  --account-name "${storage_account}" \
  --container-name "${container}" \
  --name "${old_key}" \
  --auth-mode login \
  --only-show-errors

echo
echo "Split complete."
echo "Backup blob: lanes.tfstate.pre-split"
echo "Next, from stacks/lanes, with the same terraform.tfvars except cost_centre:"
echo "  terraform init -input=false -reconfigure -backend-config=backend.hcl -backend-config=key=lanes/cc-0000.tfstate"
echo "  # cost_centre = \"cc-0000\" in terraform.tfvars"
echo "  terraform plan"
echo "  terraform init -input=false -reconfigure -backend-config=backend.hcl -backend-config=key=lanes/shared.tfstate"
echo "  # cost_centre = \"shared\""
echo "  terraform plan"
echo "Read both plans before apply. Environments must not be created or destroyed."
echo "Apply the cost centre state first, then the shared state."
