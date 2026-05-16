#!/usr/bin/env bash
# Scan repo for secrets (local check; CI runs the same via GitHub Actions).
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required to run gitleaks"
  exit 1
fi

echo "==> gitleaks scan: ${ROOT}"
docker run --rm \
  -v "${ROOT}:/repo" \
  -w /repo \
  ghcr.io/gitleaks/gitleaks:latest \
  detect --source /repo --config /repo/.gitleaks.toml -v
