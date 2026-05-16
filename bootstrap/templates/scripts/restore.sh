#!/usr/bin/env bash
set -euo pipefail

ARCHIVE_PATH="${1:-}"

if [[ -z "${ARCHIVE_PATH}" ]]; then
  echo "Usage: /opt/homelab/scripts/restore.sh /path/to/backup.tar.gz"
  exit 1
fi

if [[ ! -f "${ARCHIVE_PATH}" ]]; then
  echo "Archive not found: ${ARCHIVE_PATH}"
  exit 1
fi

read -r -p "This will overwrite existing configs in /opt/homelab. Type RESTORE to continue: " answer
if [[ "${answer}" != "RESTORE" ]]; then
  echo "Restore cancelled."
  exit 1
fi

tar -xzf "${ARCHIVE_PATH}" -C /
echo "Restore completed from ${ARCHIVE_PATH}"
