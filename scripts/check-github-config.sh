#!/usr/bin/env bash
# Decide whether plan, apply, and drift should sign in to Azure.
# Missing repository variables skip those jobs. This script exits 0 either way
# and records ready=true or ready=false for the calling workflow.
set -euo pipefail

write_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s\n' "$1" >> "${GITHUB_OUTPUT}"
  else
    printf '%s\n' "$1"
  fi
}

write_summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$1" >> "${GITHUB_STEP_SUMMARY}"
  fi
  printf '%s\n' "$1"
}

evaluate() {
  local -a missing=()
  local name value location macro geo

  for name in \
    AZURE_CLIENT_ID \
    AZURE_TENANT_ID \
    AZURE_SUBSCRIPTION_ID \
    TF_STATE_RESOURCE_GROUP \
    TF_STATE_STORAGE_ACCOUNT \
    TF_STATE_CONTAINER
  do
    value="${!name:-}"
    if [ -z "${value}" ]; then
      missing+=("${name}")
    fi
  done

  location="${POWER_PLATFORM_LOCATION:-}"
  macro="${POWER_PLATFORM_MACRO_REGION:-}"
  geo=""
  if [ -n "${location}" ] && [ -n "${macro}" ]; then
    geo="Set only one of POWER_PLATFORM_LOCATION or POWER_PLATFORM_MACRO_REGION."
  elif [ -z "${location}" ] && [ -z "${macro}" ]; then
    geo="Set one of POWER_PLATFORM_LOCATION or POWER_PLATFORM_MACRO_REGION."
  fi

  if [ "${#missing[@]}" -eq 0 ] && [ -z "${geo}" ]; then
    write_output "ready=true"
    write_summary "### Azure configuration"
    write_summary "Repository variables are set. Plan, apply, and drift will sign in with OIDC."
    write_summary "A missing federated credential still fails the Azure login step."
    return 0
  fi

  write_output "ready=false"
  write_summary "### Azure configuration is not ready"
  write_summary "Plan, apply, and drift are skipped, so this check stays green. Format and validate still run on pull requests."
  if [ "${#missing[@]}" -gt 0 ]; then
    write_summary ""
    write_summary "Missing repository variables:"
    for name in "${missing[@]}"; do
      write_summary "- \`${name}\`"
    done
  fi
  if [ -n "${geo}" ]; then
    write_summary ""
    write_summary "${geo}"
  fi
  write_summary ""
  write_summary "See the README section on GitHub Actions. OIDC is checked only after these variables are set."
  echo "::notice title=Azure configuration is not ready::Plan, apply, and drift are skipped until the repository variables are set. The job summary lists them."
}

self_test() {
  local dir out sum
  dir="$(mktemp -d)"
  out="${dir}/out"
  sum="${dir}/sum"

  run_case() {
    : > "${out}"
    : > "${sum}"
    env -u AZURE_CLIENT_ID -u AZURE_TENANT_ID -u AZURE_SUBSCRIPTION_ID \
      -u TF_STATE_RESOURCE_GROUP -u TF_STATE_STORAGE_ACCOUNT -u TF_STATE_CONTAINER \
      -u POWER_PLATFORM_LOCATION -u POWER_PLATFORM_MACRO_REGION \
      GITHUB_OUTPUT="${out}" GITHUB_STEP_SUMMARY="${sum}" \
      "$@" bash "${BASH_SOURCE[0]}" >/dev/null
  }

  run_case
  grep -qx 'ready=false' "${out}"
  grep -q 'AZURE_CLIENT_ID' "${sum}"
  grep -q 'POWER_PLATFORM_LOCATION' "${sum}"

  run_case \
    AZURE_CLIENT_ID=client AZURE_TENANT_ID=tenant AZURE_SUBSCRIPTION_ID=sub \
    TF_STATE_RESOURCE_GROUP=rg TF_STATE_STORAGE_ACCOUNT=st TF_STATE_CONTAINER=tfstate \
    POWER_PLATFORM_LOCATION=europe POWER_PLATFORM_MACRO_REGION=eu-efta
  grep -qx 'ready=false' "${out}"
  grep -q 'only one' "${sum}"

  run_case \
    AZURE_CLIENT_ID=client AZURE_TENANT_ID=tenant AZURE_SUBSCRIPTION_ID=sub \
    TF_STATE_RESOURCE_GROUP=rg TF_STATE_STORAGE_ACCOUNT=st TF_STATE_CONTAINER=tfstate \
    POWER_PLATFORM_LOCATION=europe
  grep -qx 'ready=true' "${out}"

  run_case \
    AZURE_CLIENT_ID=client AZURE_TENANT_ID=tenant AZURE_SUBSCRIPTION_ID=sub \
    TF_STATE_RESOURCE_GROUP=rg TF_STATE_STORAGE_ACCOUNT=st TF_STATE_CONTAINER=tfstate \
    POWER_PLATFORM_MACRO_REGION=eu-efta
  grep -qx 'ready=true' "${out}"

  rm -rf "${dir}"
  echo "github config self-test passed"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit 0
fi

evaluate
