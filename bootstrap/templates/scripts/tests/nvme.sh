#!/usr/bin/env bash
# NVMe health checks for homelab (boot drive + monitoring).
set -uo pipefail

PASS=0
FAIL=0
WARN=0

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

pass() { echo "[PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }
warn() { echo "[WARN] $*"; WARN=$((WARN + 1)); }

echo "==> NVMe tests"
echo

# --- Device present ---
if [[ -b /dev/nvme0n1 ]]; then
  pass "Block device /dev/nvme0n1 exists"
else
  fail "Block device /dev/nvme0n1 not found"
fi

if [[ -c /dev/nvme0 ]]; then
  pass "NVMe controller /dev/nvme0 exists"
else
  fail "NVMe controller /dev/nvme0 not found"
fi

# --- Model (informational) ---
if command -v nvme >/dev/null 2>&1 && [[ -c /dev/nvme0 ]]; then
  model="$("${SUDO[@]}" nvme id-ctrl /dev/nvme0 2>/dev/null | sed -n 's/^mn[[:space:]]*:[[:space:]]*//p' | head -n1 || true)"
  if [[ -n "${model}" ]]; then
    pass "Drive model: ${model}"
  else
    warn "Could not read NVMe model (non-fatal)"
  fi
else
  warn "nvme-cli missing or no controller; skipping model check"
fi

# --- Temperature readable ---
temp_c=""
if command -v nvme >/dev/null 2>&1 && [[ -c /dev/nvme0 ]]; then
  temp_c="$("${SUDO[@]}" nvme smart-log /dev/nvme0 2>/dev/null | grep -iE '^temperature[[:space:]]*:' | head -1 | grep -oE '[0-9]+' | head -1 || true)"
fi
if [[ -z "${temp_c}" ]] && command -v smartctl >/dev/null 2>&1; then
  temp_c="$("${SUDO[@]}" smartctl -a /dev/nvme0n1 2>/dev/null | awk '/^Temperature:/ { print $2; exit }' || true)"
fi
if [[ -n "${temp_c}" ]] && [[ "${temp_c}" =~ ^[0-9]+$ ]]; then
  if [[ "${temp_c}" -lt 70 ]]; then
    pass "Temperature ${temp_c}°C (below 70°C warning threshold)"
  elif [[ "${temp_c}" -lt 85 ]]; then
    warn "Temperature ${temp_c}°C (warm but below critical)"
    PASS=$((PASS + 1))
  else
    fail "Temperature ${temp_c}°C (very high)"
  fi
else
  fail "Could not read NVMe temperature (install nvme-cli / smartmontools)"
fi

# --- Homelab power tuning (persistent) ---
power_sysfs="/sys/block/nvme0n1/device/power/control"
if [[ -f "${power_sysfs}" ]]; then
  power_val="$(cat "${power_sysfs}" 2>/dev/null || true)"
  if [[ "${power_val}" == "on" ]]; then
    pass "Kernel power/control is on (${power_sysfs})"
  else
    warn "power/control is '${power_val}' (expected on); run: sudo ./setup.sh --install"
  fi
else
  warn "Missing ${power_sysfs}"
fi

udev_rule="/etc/udev/rules.d/99-homelab-nvme-no-idle.rules"
if [[ -f "${udev_rule}" ]]; then
  pass "Homelab udev rule installed (${udev_rule})"
else
  warn "Homelab udev rule not found (${udev_rule}); run: sudo ./setup.sh --install"
fi

cmdline_file=""
for f in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
  [[ -f "${f}" ]] && cmdline_file="${f}" && break
done
if [[ -n "${cmdline_file}" ]] && grep -qF "nvme_core.default_ps_max_latency_us=0" "${cmdline_file}"; then
  pass "Kernel cmdline has nvme_core.default_ps_max_latency_us=0 (${cmdline_file})"
else
  warn "Kernel cmdline missing nvme_core.default_ps_max_latency_us=0; run: sudo ./setup.sh --install and reboot"
fi

# --- smartctl-exporter (optional stack check) ---
if command -v curl >/dev/null 2>&1; then
  if curl -sf --max-time 3 http://127.0.0.1:9633/metrics 2>/dev/null | grep -q 'smartctl_device_temperature'; then
    pass "smartctl-exporter exposes smartctl_device_temperature on :9633"
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'smartctl-exporter'; then
    warn "smartctl-exporter container running but no temperature metric on :9633 yet"
  else
    warn "smartctl-exporter not running (optional; homelab monitoring)"
  fi
else
  warn "curl not available; skipping exporter metrics check"
fi

echo
echo "==> NVMe summary: ${PASS} passed, ${WARN} warnings, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
