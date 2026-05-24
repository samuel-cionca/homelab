#!/usr/bin/env bash
# pi5-power-exporter.sh — emit Pi 5 PMIC / throttle metrics for node-exporter's
# textfile collector. Runs on the host (vcgencmd talks to /dev/vcio) and writes
# an atomically-replaced .prom file into the directory mounted into node-exporter.
#
# Metrics emitted:
#   pi5_throttled_flags                 raw bitmask from `vcgencmd get_throttled`
#   pi5_throttled{flag=...}             0/1 per decoded throttling bit
#   pi5_pmic_volts{rail=...}            PMIC ADC voltages (EXT5V_V, VDD_CORE_V, ...)
#   pi5_pmic_current_amps{rail=...}     PMIC ADC currents (VDD_CORE_A, 3V3_SYS_A, ...)
#   pi5_measure_volts{rail=...}         firmware-reported rails (core, sdram_*)
#   pi5_power_exporter_up               1 on success, 0 if vcgencmd missing
#   pi5_power_exporter_last_run_seconds unix timestamp of the last successful write
set -euo pipefail

OUT_DIR="${OUT_DIR:-/opt/homelab/configs/node-exporter/textfile}"
OUT="${OUT_DIR}/pi5_power.prom"
TMP="${OUT}.$$"

mkdir -p "${OUT_DIR}"

# Clean stale .prom.<pid> temp files left by previously interrupted runs.
# Skip any whose owning PID is still alive (concurrent run, very unlikely).
shopt -s nullglob
for f in "${OUT}".[0-9]*; do
  pid="${f##*.}"
  if [[ "${pid}" =~ ^[0-9]+$ ]] && ! kill -0 "${pid}" 2>/dev/null; then
    rm -f "${f}"
  fi
done
shopt -u nullglob

trap 'rm -f "${TMP}" 2>/dev/null || true' EXIT

emit_unavailable() {
  cat >"${TMP}" <<'EOF'
# HELP pi5_power_exporter_up 1 if vcgencmd is usable on this host, 0 otherwise
# TYPE pi5_power_exporter_up gauge
pi5_power_exporter_up 0
EOF
  mv "${TMP}" "${OUT}"
}

if ! command -v vcgencmd >/dev/null 2>&1; then
  emit_unavailable
  exit 0
fi

throttled_raw="$(vcgencmd get_throttled 2>/dev/null | awk -F'=' '{print $2}')"
if [[ -z "${throttled_raw}" ]]; then
  emit_unavailable
  exit 0
fi
throttled_dec=$((throttled_raw))

{
  echo "# HELP pi5_throttled_flags Raw bitmask returned by vcgencmd get_throttled"
  echo "# TYPE pi5_throttled_flags gauge"
  echo "pi5_throttled_flags ${throttled_dec}"

  echo "# HELP pi5_throttled Decoded throttling/under-voltage bits (1 = condition seen)"
  echo "# TYPE pi5_throttled gauge"
  for bit_def in \
    0:undervoltage_now \
    1:freqcap_now \
    2:throttled_now \
    3:tempcap_now \
    16:undervoltage_since_boot \
    17:freqcap_since_boot \
    18:throttled_since_boot \
    19:tempcap_since_boot; do
    bit="${bit_def%%:*}"
    name="${bit_def##*:}"
    val=$(( (throttled_dec >> bit) & 1 ))
    echo "pi5_throttled{flag=\"${name}\"} ${val}"
  done

  pmic_out="$(vcgencmd pmic_read_adc 2>/dev/null || true)"
  if [[ -n "${pmic_out}" ]]; then
    echo "# HELP pi5_pmic_volts PMIC ADC voltage rails (V)"
    echo "# TYPE pi5_pmic_volts gauge"
    echo "# HELP pi5_pmic_current_amps PMIC ADC current rails (A)"
    echo "# TYPE pi5_pmic_current_amps gauge"
    printf '%s\n' "${pmic_out}" | awk '
      $2 ~ /current\(/ {
        rail=$1; val=$2
        sub(/.*=/, "", val); sub(/A$/, "", val)
        printf "pi5_pmic_current_amps{rail=\"%s\"} %s\n", rail, val
      }
      $2 ~ /volt\(/ {
        rail=$1; val=$2
        sub(/.*=/, "", val); sub(/V$/, "", val)
        printf "pi5_pmic_volts{rail=\"%s\"} %s\n", rail, val
      }
    '
  fi

  echo "# HELP pi5_measure_volts Firmware-reported rail voltages (V)"
  echo "# TYPE pi5_measure_volts gauge"
  for rail in core sdram_c sdram_i sdram_p; do
    raw="$(vcgencmd measure_volts "${rail}" 2>/dev/null | awk -F'=' '{print $2}')" || true
    [[ -z "${raw}" ]] && continue
    val="${raw%V}"
    echo "pi5_measure_volts{rail=\"${rail}\"} ${val}"
  done

  echo "# HELP pi5_power_exporter_up 1 if vcgencmd is usable on this host, 0 otherwise"
  echo "# TYPE pi5_power_exporter_up gauge"
  echo "pi5_power_exporter_up 1"

  echo "# HELP pi5_power_exporter_last_run_seconds Unix timestamp of the last successful run"
  echo "# TYPE pi5_power_exporter_last_run_seconds gauge"
  echo "pi5_power_exporter_last_run_seconds $(date +%s)"
} >"${TMP}"

chmod 0644 "${TMP}"
mv "${TMP}" "${OUT}"
