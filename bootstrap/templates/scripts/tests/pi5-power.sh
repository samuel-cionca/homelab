#!/usr/bin/env bash
# Pi 5 PMIC / throttle / under-voltage exporter health checks.
set -uo pipefail

PASS=0
FAIL=0
WARN=0
SKIP=0

pass() { echo "[PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }
warn() { echo "[WARN] $*"; WARN=$((WARN + 1)); }
skip() { echo "[SKIP] $*"; SKIP=$((SKIP + 1)); }

echo "==> Pi 5 power tests"
echo

model=""
if [[ -r /proc/device-tree/model ]]; then
  model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
fi

if [[ "${model}" != *"Raspberry Pi 5"* ]]; then
  skip "Not a Raspberry Pi 5 (model: ${model:-unknown}); skipping rest of suite"
  echo
  echo "==> Pi 5 power summary: ${PASS} passed, ${WARN} warnings, ${FAIL} failed, ${SKIP} skipped"
  exit 0
fi

if command -v vcgencmd >/dev/null 2>&1; then
  pass "vcgencmd is available"
else
  fail "vcgencmd not found in PATH (install raspi-config / libraspberrypi-bin)"
fi

throttled_raw=""
if command -v vcgencmd >/dev/null 2>&1; then
  throttled_raw="$(vcgencmd get_throttled 2>/dev/null | awk -F'=' '{print $2}')"
fi
if [[ -n "${throttled_raw}" ]]; then
  pass "vcgencmd get_throttled returned ${throttled_raw}"
  throttled_dec=$((throttled_raw))
  if (( (throttled_dec & 0x1) != 0 )); then
    fail "Under-voltage condition is currently active (bit 0); check PSU/cable"
  fi
  if (( (throttled_dec & 0x10000) != 0 )); then
    warn "Under-voltage occurred since boot (bit 16); a PSU dip happened"
  fi
  if (( (throttled_dec & 0x40000) != 0 )); then
    warn "Throttling occurred since boot (bit 18)"
  fi
else
  warn "Could not read vcgencmd get_throttled"
fi

if [[ -f /etc/systemd/system/pi5-power-exporter.service ]]; then
  pass "pi5-power-exporter.service unit installed"
else
  fail "pi5-power-exporter.service not installed; run: sudo ./bootstrap/setup.sh --install"
fi

if [[ -f /etc/systemd/system/pi5-power-exporter.timer ]]; then
  pass "pi5-power-exporter.timer unit installed"
  if systemctl is-active --quiet pi5-power-exporter.timer 2>/dev/null; then
    pass "pi5-power-exporter.timer is active"
  else
    warn "pi5-power-exporter.timer is not active; try: sudo systemctl enable --now pi5-power-exporter.timer"
  fi
else
  fail "pi5-power-exporter.timer not installed; run: sudo ./bootstrap/setup.sh --install"
fi

prom_file="/opt/homelab/configs/node-exporter/textfile/pi5_power.prom"
if [[ -f "${prom_file}" ]]; then
  pass "Textfile metrics present at ${prom_file}"
  age=$(( $(date +%s) - $(stat -c %Y "${prom_file}" 2>/dev/null || echo 0) ))
  if (( age < 60 )); then
    pass "Metrics file updated ${age}s ago (<60s)"
  elif (( age < 600 )); then
    warn "Metrics file is ${age}s old; timer may be skipped or slow"
  else
    fail "Metrics file is stale (${age}s); check timer/service logs"
  fi
  if grep -q '^pi5_throttled_flags ' "${prom_file}"; then
    pass "Throttle bitmask metric present"
  else
    warn "Throttle bitmask metric missing from ${prom_file}"
  fi
  if grep -q '^pi5_pmic_volts{rail="EXT5V_V"' "${prom_file}"; then
    pass "EXT5V_V rail metric present"
  else
    warn "EXT5V_V rail metric missing (vcgencmd pmic_read_adc may be unsupported)"
  fi
else
  fail "Textfile metrics not found at ${prom_file}; run: sudo systemctl start pi5-power-exporter.service"
fi

if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'node-exporter'; then
  ne_name="$(docker ps --format '{{.Names}}' | grep node-exporter | head -1)"
  if docker exec "${ne_name}" wget -qO- localhost:9100/metrics 2>/dev/null | grep -q '^pi5_throttled_flags'; then
    pass "node-exporter exposes pi5_throttled_flags (container ${ne_name})"
  else
    warn "node-exporter container running but no pi5 metric exposed yet; check --collector.textfile.directory flag and volume mount"
  fi
else
  warn "node-exporter container not running (optional check)"
fi

if command -v curl >/dev/null 2>&1; then
  prom_result="$(curl -sf --max-time 3 'http://127.0.0.1:9090/api/v1/query?query=pi5_throttled_flags' 2>/dev/null || true)"
  if [[ -n "${prom_result}" ]] && echo "${prom_result}" | grep -q '"pi5_throttled_flags"'; then
    pass "Prometheus is scraping pi5_throttled_flags on :9090"
  elif [[ -n "${prom_result}" ]]; then
    warn "Prometheus reachable but pi5_throttled_flags not yet present (wait for next scrape, ~15 s)"
  else
    warn "Prometheus not reachable on :9090 (optional check)"
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# Power-stability audit: settings that should be applied by the bootstrap.
# Each is a deliberate trade-off (a bit more power for fewer freezes / hangs).
# ──────────────────────────────────────────────────────────────────────────────
echo
echo "── Power-stability audit ──"

cmdline_file=""
for f in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
  if [[ -f "$f" ]] && head -n1 "$f" | grep -q '='; then
    cmdline_file="$f"
    break
  fi
done

cmdline_has() {
  [[ -n "${cmdline_file}" ]] && grep -qE "(^|[[:space:]])$1([[:space:]]|$)" "${cmdline_file}"
}

if [[ -n "${cmdline_file}" ]]; then
  pass "Kernel cmdline file: ${cmdline_file}"
else
  fail "No kernel cmdline file (/boot/firmware/cmdline.txt) found"
fi

if cmdline_has 'pcie_aspm=off'; then
  pass "PCIe ASPM is disabled (pcie_aspm=off) in cmdline"
else
  warn "pcie_aspm=off not present in cmdline; run: sudo ./bootstrap/setup.sh --install (then reboot)"
fi

shopt -s nullglob
nonD0=()
for f in /sys/bus/pci/devices/*/power_state; do
  state="$(cat "$f" 2>/dev/null || echo unknown)"
  [[ "${state}" == "D0" ]] || nonD0+=("$(basename "$(dirname "$f")"):${state}")
done
shopt -u nullglob
if [[ ${#nonD0[@]} -eq 0 ]]; then
  pass "All PCIe devices are in D0 (active)"
else
  warn "PCIe devices not in D0: ${nonD0[*]}"
fi

if cmdline_has 'nvme_core.default_ps_max_latency_us=0'; then
  pass "NVMe APST disabled (nvme_core.default_ps_max_latency_us=0) in cmdline"
else
  warn "NVMe APST cmdline missing; run: sudo ./bootstrap/setup.sh --install (then reboot)"
fi

nvme_pwr="/sys/block/nvme0n1/device/power/control"
if [[ -r "${nvme_pwr}" ]]; then
  v="$(cat "${nvme_pwr}")"
  if [[ "${v}" == "on" ]]; then
    pass "NVMe runtime PM disabled (${nvme_pwr} = on)"
  else
    warn "NVMe runtime PM is '${v}' (expected 'on'); check udev rule"
  fi
fi

bt_ertm="/sys/module/bluetooth/parameters/disable_ertm"
if [[ -r "${bt_ertm}" ]]; then
  if [[ "$(cat "${bt_ertm}")" == "Y" ]]; then
    pass "Bluetooth ERTM disabled (disable_ertm=Y)"
  else
    warn "Bluetooth ERTM enabled (disable_ertm=N); reboot to apply modprobe drop-in"
  fi
fi

if command -v iw >/dev/null 2>&1; then
  wlan="$(iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}')"
  if [[ -n "${wlan}" ]]; then
    ps="$(iw dev "${wlan}" get power_save 2>/dev/null | awk -F': ' '{print $2}')"
    if [[ "${ps}" == "off" ]]; then
      pass "Wi-Fi powersave is off on ${wlan}"
    else
      warn "Wi-Fi powersave is '${ps}' on ${wlan} (expected off)"
    fi
  fi
fi

nm_drop="/etc/NetworkManager/conf.d/wifi-powersave.conf"
if [[ -f "${nm_drop}" ]] && grep -q 'wifi.powersave[[:space:]]*=[[:space:]]*2' "${nm_drop}"; then
  pass "NetworkManager wifi-powersave dropin present (wifi.powersave=2)"
else
  warn "NetworkManager wifi-powersave dropin missing or not set to 2; run: sudo ./bootstrap/setup.sh --install"
fi
if [[ -f /etc/NetworkManager/conf.d/default-wifi-powersave-on.conf ]]; then
  warn "Debian's default-wifi-powersave-on.conf is also present (redundant with homelab dropin; harmless)"
fi

gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
case "${gov}" in
  ondemand|schedutil|performance)
    pass "CPU governor: ${gov}"
    ;;
  powersave)
    warn "CPU governor is 'powersave' — may cause sluggishness; consider 'ondemand'"
    ;;
  unknown)
    warn "Could not read CPU governor"
    ;;
  *)
    warn "CPU governor is '${gov}' (non-standard)"
    ;;
esac

if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq ]]; then
  mhz=$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq) / 1000 ))
  if (( mhz >= 2400 )); then
    pass "CPU max frequency: ${mhz} MHz"
  else
    warn "CPU max frequency capped at ${mhz} MHz (Pi 5 default is 2400)"
  fi
fi

echo
echo "==> Pi 5 power summary: ${PASS} passed, ${WARN} warnings, ${FAIL} failed, ${SKIP} skipped"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
