#!/usr/bin/env bash
# Format-check and validate every root module without a backend or credentials.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! python3 -c "import yaml" >/dev/null 2>&1; then
  python3 -m pip install --user pyyaml
fi

python3 "${root}/scripts/check-lanes.py" --self-test
python3 "${root}/scripts/check-lanes.py" --root "${root}"
bash "${root}/scripts/check-github-config.sh" --self-test

terraform fmt -check -recursive "${root}"

roots=(
  "${root}/stacks/tenant"
  "${root}/stacks/groups"
  "${root}/stacks/lanes"
  "${root}/examples/register-admin-application"
  "${root}/examples/tenant-isolation"
)

for dir in "${roots[@]}"; do
  echo "==> ${dir#"${root}/"}"
  terraform -chdir="${dir}" init -backend=false -input=false -no-color
  terraform -chdir="${dir}" validate -no-color
done

echo "validate-all passed"
