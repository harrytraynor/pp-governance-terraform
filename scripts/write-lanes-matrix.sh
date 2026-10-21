#!/usr/bin/env bash
# Print the lanes CI matrix, or append it to GITHUB_OUTPUT when that variable is set.
#   scripts/write-lanes-matrix.sh all
#   scripts/write-lanes-matrix.sh diff BASE HEAD
# A missing base commit selects every cost centre. An empty diff selects none.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-}"

if [ "${mode}" != "all" ] && [ "${mode}" != "diff" ]; then
  echo "Usage: scripts/write-lanes-matrix.sh all | diff BASE HEAD" >&2
  exit 2
fi

run_matrix() {
  local -a cmd
  cmd=(python3 "${root}/scripts/lane_states.py" --root "${root}" matrix)
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    cmd+=(--github-output "${GITHUB_OUTPUT}")
  fi
  cmd+=("$@")
  "${cmd[@]}"
}

if [ "${mode}" = "all" ]; then
  run_matrix --all
  exit 0
fi

base="${2:-}"
head="${3:-HEAD}"
if [ -z "${base}" ] || [ "${base}" = "0000000000000000000000000000000000000000" ] || ! git -C "${root}" cat-file -e "${base}^{commit}" 2>/dev/null; then
  run_matrix --all
  exit 0
fi

file_args=()
while IFS= read -r file; do
  if [ -n "${file}" ]; then
    file_args+=(--changed-file "${file}")
  fi
done < <(git -C "${root}" diff --name-only "${base}" "${head}")
run_matrix "${file_args[@]}"
