#!/usr/bin/env bash
# Homelab health checks. Usage: test.sh [suite]
# Suites: nvme | all (default: all)
set -euo pipefail

BASE_DIR="${BASE_DIR:-/opt/homelab}"
SUITE="${1:-all}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${SCRIPT_DIR}/tests"

usage() {
  cat <<'EOF'
Usage: test.sh [suite]

Suites:
  nvme   Boot NVMe device, temperature, power tuning, optional exporter
  all    Run all suites (default)

Examples:
  /opt/homelab/scripts/test.sh
  /opt/homelab/scripts/test.sh nvme
  sudo ./setup.sh --test
  sudo ./setup.sh --test-nvme
EOF
}

run_suite() {
  local name="$1"
  local script="${TESTS_DIR}/${name}.sh"
  if [[ ! -f "${script}" ]]; then
    echo "Unknown or missing test suite: ${name}"
    return 1
  fi
  echo "────────────────────────────────────────"
  bash "${script}"
}

case "${SUITE}" in
  -h|--help)
    usage
    exit 0
    ;;
  all)
    failed=0
    run_suite nvme || failed=1
    echo "────────────────────────────────────────"
    if [[ "${failed}" -eq 0 ]]; then
      echo "==> All suites passed"
    else
      echo "==> One or more suites failed"
      exit 1
    fi
    ;;
  nvme)
    run_suite nvme
    ;;
  *)
    echo "Unknown suite: ${SUITE}"
    usage
    exit 1
    ;;
esac
