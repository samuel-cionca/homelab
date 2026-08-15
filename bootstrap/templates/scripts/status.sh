#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/opt/homelab/scripts/lib/stacks.sh
source "${SCRIPT_DIR}/lib/stacks.sh"

echo "==> Compose projects"
docker compose ls

echo
echo "==> Docker containers"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

echo
echo "==> Stack status"
while IFS= read -r dir; do
  echo
  echo "-- ${dir} --"
  homelab_compose "${dir}" ps
done < <(homelab_stack_dirs)

echo
echo "==> Disk usage"
df -h

echo
echo "==> Docker disk usage"
docker system df

echo
echo "==> Memory"
free -h
