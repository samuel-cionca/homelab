#!/usr/bin/env bash
set -euo pipefail

SERVICE="${1:-}"

cd /opt/homelab

if [[ -z "${SERVICE}" ]]; then
  docker compose logs -f --tail=100
else
  docker compose logs -f --tail=100 "${SERVICE}"
fi
