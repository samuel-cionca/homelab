#!/usr/bin/env bash
set -euo pipefail

cd /opt/homelab

docker compose pull
docker compose up -d
docker image prune -f

echo "Update complete."
