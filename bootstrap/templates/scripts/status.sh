#!/usr/bin/env bash
set -euo pipefail

cd /opt/homelab

echo "==> Docker containers"
docker compose ps

echo
echo "==> Disk usage"
df -h

echo
echo "==> Docker disk usage"
docker system df

echo
echo "==> Memory"
free -h
