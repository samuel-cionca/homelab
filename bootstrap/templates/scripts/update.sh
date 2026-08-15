#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/opt/homelab/scripts/lib/stacks.sh
source "${SCRIPT_DIR}/lib/stacks.sh"

while IFS= read -r dir; do
  echo "==> Updating ${dir}"
  homelab_compose "${dir}" pull --ignore-buildable || homelab_compose "${dir}" pull || true
  homelab_compose "${dir}" up -d --remove-orphans --build
done < <(homelab_stack_dirs)

docker image prune -f

echo "Update complete."
