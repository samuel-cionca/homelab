#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/opt/homelab/data/backups"
TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
OUTPUT_FILE="${BACKUP_DIR}/homelab-configs-${TIMESTAMP}.tar.gz"

mkdir -p "${BACKUP_DIR}"

tar -czf "${OUTPUT_FILE}" \
  /opt/homelab/.env \
  /opt/homelab/docker-compose.yml \
  /opt/homelab/configs

echo "Backup created:"
echo "${OUTPUT_FILE}"
