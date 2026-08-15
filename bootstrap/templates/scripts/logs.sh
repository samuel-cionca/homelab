#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/opt/homelab/scripts/lib/stacks.sh
source "${SCRIPT_DIR}/lib/stacks.sh"

SERVICE="${1:-}"

if [[ -z "${SERVICE}" ]]; then
  while IFS= read -r dir; do
    echo "==> logs ${dir}"
    homelab_compose "${dir}" logs --tail=50
  done < <(homelab_stack_dirs)
  exit 0
fi

while IFS= read -r dir; do
  if homelab_compose "${dir}" config --services 2>/dev/null | grep -qx "${SERVICE}"; then
    homelab_compose "${dir}" logs -f --tail=100 "${SERVICE}"
    exit 0
  fi
done < <(homelab_stack_dirs)

echo "Service not found in any stack: ${SERVICE}"
exit 1
