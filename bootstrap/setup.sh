#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"

BASE_DIR="/opt/homelab"
GRAFANA_UID=472
GRAFANA_GID=472
FORCE=0
CLEAN_INSTALL=0
NVME_CMDLINE_NEEDS_REBOOT=0
PI5_BLUETOOTH_MODPROBE_NEEDS_REBOOT=0
HOST=""
HOST_DIR=""
SYSTEMS_DIR=""
TEST_SUITE="all"

ACTION="install"

usage() {
  cat <<'EOF'
Usage:
  ./bootstrap/setup.sh [--host NAME] [--install|--update|--backup|--restart|--test|--test-nvme|--reset] [--force] [--clean-install]

Actions:
  --install   Install tools, Docker (if missing), NVMe tuning, Pi 5 WiFi/BT tweaks, Neovim, and homelab stack (default)
  --update    Pull and recreate containers, then prune old images
  --backup    Create config backup archive
  --restart   Restart containers
  --test      Run health checks (all suites)
  --test-nvme Run NVMe health checks only
  --reset     Stop stack and remove /opt/homelab (destructive)

Flags:
  --host NAME             Host profile under hosts/NAME/ and systems/NAME/ (default: match hostname if present)
  --force                 Overwrite existing managed files during install
  --clean-install         Recreate all containers if the stack already exists
  --recreate-containers   Alias of --clean-install
  -h, --help              Show this help

Examples:
  sudo ./bootstrap/setup.sh --host pi5-sol --install
  sudo ./bootstrap/setup.sh --test-nvme
EOF
}

log() {
  echo "==> $*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run with sudo/root: sudo ./bootstrap/setup.sh ..."
    exit 1
  fi
}

resolve_host() {
  if [[ -z "${HOST}" ]]; then
    local candidates=()
    local h
    h="$(hostname -s 2>/dev/null || true)"
    [[ -n "${h}" ]] && candidates+=("${h}")
    h="$(hostname 2>/dev/null || true)"
    [[ -n "${h}" ]] && candidates+=("${h}")
    for h in "${candidates[@]}"; do
      if [[ -d "${REPO_ROOT}/hosts/${h}" ]]; then
        HOST="${h}"
        break
      fi
    done
  fi

  if [[ -n "${HOST}" ]]; then
    HOST_DIR="${REPO_ROOT}/hosts/${HOST}"
    SYSTEMS_DIR="${REPO_ROOT}/systems/${HOST}"
    if [[ ! -d "${HOST_DIR}" ]]; then
      echo "Unknown host profile: ${HOST} (missing ${HOST_DIR})"
      exit 1
    fi
    log "Using host profile: ${HOST}"
  fi
}

install_host_tools() {
  log "Installing host tools (btop, glances, etc.)"
  apt update
  apt install -y \
    btop \
    glances \
    htop \
    git \
    curl \
    wget \
    unzip \
    jq \
    ncdu \
    tree \
    vim \
    tmux \
    ufw \
    smartmontools \
    nvme-cli \
    ca-certificates \
    gnupg
}

install_neovim_latest_stable() {
  log "Installing latest stable Neovim"
  local tmpdir appimage_url version_url
  tmpdir="$(mktemp -d)"

  version_url="https://api.github.com/repos/neovim/neovim/releases/latest"
  appimage_url="$(curl -fsSL "$version_url" | jq -r '.assets[] | select(.name == "nvim-linux-arm64.appimage") | .browser_download_url')"

  if [[ -z "${appimage_url}" || "${appimage_url}" == "null" ]]; then
    appimage_url="$(curl -fsSL "$version_url" | jq -r '.assets[] | select(.name == "nvim.appimage") | .browser_download_url' | head -n1)"
  fi

  if [[ -z "${appimage_url}" || "${appimage_url}" == "null" ]]; then
    echo "Could not resolve Neovim stable AppImage URL."
    exit 1
  fi

  curl -fL "$appimage_url" -o "${tmpdir}/nvim.appimage"
  chmod +x "${tmpdir}/nvim.appimage"
  install -m 0755 "${tmpdir}/nvim.appimage" /usr/local/bin/nvim
  rm -rf "${tmpdir}"
}

install_docker_if_missing() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed"
  else
    log "Installing Docker"
    curl -fsSL https://get.docker.com | sh
  fi

  systemctl enable docker
  systemctl start docker

  local docker_user="${SUDO_USER:-root}"
  if id -nG "${docker_user}" | grep -qw docker; then
    log "User ${docker_user} already in docker group"
  else
    log "Adding ${docker_user} to docker group"
    usermod -aG docker "${docker_user}"
  fi
}

create_structure() {
  log "Creating homelab directory structure"
  mkdir -p \
    "${BASE_DIR}/scripts" \
    "${BASE_DIR}/scripts/tests" \
    "${BASE_DIR}/configs/portainer" \
    "${BASE_DIR}/configs/uptime-kuma" \
    "${BASE_DIR}/configs/homepage" \
    "${BASE_DIR}/configs/pihole" \
    "${BASE_DIR}/configs/pihole-dnsmasq" \
    "${BASE_DIR}/configs/wg-easy" \
    "${BASE_DIR}/configs/homeassistant" \
    "${BASE_DIR}/configs/jellyfin" \
    "${BASE_DIR}/configs/jellyfin-cache" \
    "${BASE_DIR}/configs/prometheus" \
    "${BASE_DIR}/configs/grafana/data" \
    "${BASE_DIR}/configs/grafana/provisioning/datasources" \
    "${BASE_DIR}/configs/grafana/provisioning/dashboards" \
    "${BASE_DIR}/configs/grafana/provisioning/dashboards/json" \
    "${BASE_DIR}/configs/smartctl-exporter" \
    "${BASE_DIR}/data/backups" \
    "${BASE_DIR}/media/movies" \
    "${BASE_DIR}/media/series" \
    "${BASE_DIR}/media/music" \
    "${BASE_DIR}/media/photos"
}

copy_file_if_needed() {
  local src="$1"
  local dst="$2"

  if [[ -f "${dst}" && "${FORCE}" -eq 0 ]]; then
    log "Skipping existing file: ${dst}"
    return 0
  fi

  install -m 0644 "${src}" "${dst}"
  log "Wrote: ${dst}"
}

copy_script_if_needed() {
  local src="$1"
  local dst="$2"

  if [[ -f "${dst}" && "${FORCE}" -eq 0 ]]; then
    log "Skipping existing script: ${dst}"
    return 0
  fi

  install -m 0755 "${src}" "${dst}"
  log "Wrote script: ${dst}"
}

template_src() {
  local rel="$1"
  local sys="${SYSTEMS_DIR}/${rel}"
  if [[ -n "${SYSTEMS_DIR}" && -f "${sys}" ]]; then
    echo "${sys}"
  else
    echo "${TEMPLATES_DIR}/${rel}"
  fi
}

create_env_file() {
  local env_file="${BASE_DIR}/.env"
  local tmp

  if [[ -f "${env_file}" && "${FORCE}" -eq 0 ]]; then
    log ".env already exists, keeping current secrets"
    return 0
  fi

  tmp="$(mktemp)"
  cat "${TEMPLATES_DIR}/.env.example" >"${tmp}"
  if [[ -n "${HOST_DIR}" && -f "${HOST_DIR}/host.env" ]]; then
    grep -v '^[[:space:]]*#' "${HOST_DIR}/host.env" | grep -v '^[[:space:]]*$' >>"${tmp}" || true
  fi
  if [[ -n "${HOST_DIR}" && -f "${HOST_DIR}/secrets.env" ]]; then
    grep -v '^[[:space:]]*#' "${HOST_DIR}/secrets.env" | grep -v '^[[:space:]]*$' >>"${tmp}" || true
  fi

  awk -F= '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    { key=$1; val=substr($0, index($0, "=") + 1); vals[key]=val }
    END { for (k in vals) print k "=" vals[k] }
  ' "${tmp}" >"${env_file}"
  rm -f "${tmp}"
  chmod 600 "${env_file}"
  log "Created ${env_file}"
}

populate_templates() {
  copy_file_if_needed "$(template_src docker-compose.yml)" "${BASE_DIR}/docker-compose.yml"
  create_env_file

  copy_script_if_needed "$(template_src scripts/status.sh)" "${BASE_DIR}/scripts/status.sh"
  copy_script_if_needed "$(template_src scripts/logs.sh)" "${BASE_DIR}/scripts/logs.sh"
  copy_script_if_needed "$(template_src scripts/update.sh)" "${BASE_DIR}/scripts/update.sh"
  copy_script_if_needed "$(template_src scripts/backup.sh)" "${BASE_DIR}/scripts/backup.sh"
  copy_script_if_needed "$(template_src scripts/restore.sh)" "${BASE_DIR}/scripts/restore.sh"
  copy_script_if_needed "$(template_src scripts/test.sh)" "${BASE_DIR}/scripts/test.sh"
  copy_script_if_needed "$(template_src scripts/tests/nvme.sh)" "${BASE_DIR}/scripts/tests/nvme.sh"

  copy_file_if_needed "$(template_src configs/prometheus/prometheus.yml)" "${BASE_DIR}/configs/prometheus/prometheus.yml"
  copy_file_if_needed "$(template_src configs/grafana/provisioning/datasources/prometheus.yaml)" "${BASE_DIR}/configs/grafana/provisioning/datasources/prometheus.yaml"
  copy_file_if_needed "$(template_src configs/grafana/provisioning/dashboards/provider.yaml)" "${BASE_DIR}/configs/grafana/provisioning/dashboards/provider.yaml"
  # Always sync: restarts alone do not pull JSON from git; copy_file_if_needed skips when the file exists.
  install -m 0644 "$(template_src configs/grafana/provisioning/dashboards/json/homelab-temperature.json)" "${BASE_DIR}/configs/grafana/provisioning/dashboards/json/homelab-temperature.json"
  log "Wrote: ${BASE_DIR}/configs/grafana/provisioning/dashboards/json/homelab-temperature.json"
  rm -f "${BASE_DIR}/configs/grafana/provisioning/dashboards/json/ssd-temperature.json"
  copy_file_if_needed "$(template_src smartctl-exporter/Dockerfile)" "${BASE_DIR}/configs/smartctl-exporter/Dockerfile"

  if [[ -n "${HOST_DIR}" && -f "${HOST_DIR}/docker-compose.override.yml" ]]; then
    copy_file_if_needed "${HOST_DIR}/docker-compose.override.yml" "${BASE_DIR}/docker-compose.override.yml"
  fi
}

fix_grafana_permissions() {
  local legacy_dashboard="${BASE_DIR}/configs/grafana/provisioning/dashboards/ssd-temperature.json"
  local dashboard_json_dir="${BASE_DIR}/configs/grafana/provisioning/dashboards/json"

  log "Setting Grafana data directory ownership (UID ${GRAFANA_UID})"
  mkdir -p "${BASE_DIR}/configs/grafana/data" "${dashboard_json_dir}"

  if [[ -f "${legacy_dashboard}" ]]; then
    log "Moving legacy dashboard into ${dashboard_json_dir}/"
    install -m 0644 "${legacy_dashboard}" "${dashboard_json_dir}/homelab-temperature.json"
    rm -f "${legacy_dashboard}"
  fi

  chown -R "${GRAFANA_UID}:${GRAFANA_GID}" "${BASE_DIR}/configs/grafana/data"
}

configure_nvme_power() {
  local udev_src="$(template_src nvme/99-nvme-no-idle.rules)"
  local udev_dst="/etc/udev/rules.d/99-homelab-nvme-no-idle.rules"
  local power_sysfs="/sys/block/nvme0n1/device/power/control"
  local cmdline=""
  local cmdline_param="nvme_core.default_ps_max_latency_us=0"
  local cmdline_updated=0

  if [[ ! -b /dev/nvme0n1 ]]; then
    log "No NVMe block device; skipping NVMe power tuning"
    return 0
  fi

  log "Configuring NVMe power for homelab (persistent, lightweight)"

  if [[ -f /etc/systemd/system/nvme-no-apst.service ]]; then
    systemctl disable --now nvme-no-apst.service 2>/dev/null || true
    rm -f /etc/systemd/system/nvme-no-apst.service
    systemctl daemon-reload 2>/dev/null || true
    log "Removed legacy nvme-no-apst.service (use udev + kernel cmdline instead)"
  fi

  install -m 0644 "${udev_src}" "${udev_dst}"
  udevadm control --reload-rules
  udevadm trigger --subsystem-match=nvme
  log "Installed ${udev_dst}"

  if [[ -w "${power_sysfs}" ]]; then
    echo on >"${power_sysfs}"
    log "Set ${power_sysfs} to on"
  fi

  for cmdline in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
    [[ -f "${cmdline}" ]] || continue
    if grep -qF "${cmdline_param}" "${cmdline}"; then
      log "Kernel param already present in ${cmdline}"
    else
      sed -i "s/$/ ${cmdline_param}/" "${cmdline}"
      log "Added ${cmdline_param} to ${cmdline} (reboot required)"
      cmdline_updated=1
    fi
    break
  done

  if [[ "${cmdline_updated}" -eq 1 ]]; then
    NVME_CMDLINE_NEEDS_REBOOT=1
  fi
}

device_tree_model() {
  [[ -r /proc/device-tree/model ]] || return 1
  tr -d '\0' </proc/device-tree/model
}

is_raspberry_pi_5() {
  local model=""
  model="$(device_tree_model)" || return 1
  case "${model}" in
    *"Raspberry Pi 5"*) return 0 ;;
    *) return 1 ;;
  esac
}

configure_pi5_wifi_bt_stability() {
  local wifi_src bluetooth_src nm_dst bluetooth_dst
  local wifi_changed=0 bluetooth_changed=0 model=""

  if ! is_raspberry_pi_5; then
    if model="$(device_tree_model 2>/dev/null)" && [[ -n "${model}" ]]; then
      log "Skipping Pi 5 WiFi/Bluetooth tuning (model: ${model})"
    else
      log "Skipping Pi 5 WiFi/Bluetooth tuning (device tree model unavailable)"
    fi
    return 0
  fi

  log "Applying Raspberry Pi 5 WiFi/Bluetooth stability tuning"

  wifi_src="$(template_src pi5/wifi-powersave.conf)"
  bluetooth_src="$(template_src pi5/bluetooth-disable-ertm.conf)"
  nm_dst="/etc/NetworkManager/conf.d/wifi-powersave.conf"
  bluetooth_dst="/etc/modprobe.d/99-homelab-bluetooth-disable-ertm.conf"

  if [[ -f /etc/NetworkManager/NetworkManager.conf ]] && command -v NetworkManager >/dev/null 2>&1; then
    mkdir -p /etc/NetworkManager/conf.d
    if [[ "${FORCE}" -eq 1 ]] || [[ ! -f "${nm_dst}" ]] || ! cmp -s "${wifi_src}" "${nm_dst}"; then
      install -m 0644 "${wifi_src}" "${nm_dst}"
      log "Installed ${nm_dst}"
      wifi_changed=1
    else
      log "Leaving existing NetworkManager wifi-powersave config (${nm_dst}); use --force to refresh"
    fi
    if [[ "${wifi_changed}" -eq 1 ]] && systemctl is-active --quiet NetworkManager 2>/dev/null; then
      systemctl restart NetworkManager
      log "Restarted NetworkManager"
    fi
  else
    log "Skipping NetworkManager wifi-powersave (NetworkManager not present)"
  fi

  if [[ "${FORCE}" -eq 1 ]] || [[ ! -f "${bluetooth_dst}" ]] || ! cmp -s "${bluetooth_src}" "${bluetooth_dst}"; then
    install -m 0644 "${bluetooth_src}" "${bluetooth_dst}"
    log "Installed ${bluetooth_dst}"
    bluetooth_changed=1
    PI5_BLUETOOTH_MODPROBE_NEEDS_REBOOT=1
  else
    log "Leaving existing Bluetooth modprobe (${bluetooth_dst}); use --force to refresh"
  fi

  if [[ "${bluetooth_changed}" -eq 0 ]] && [[ -r /sys/module/bluetooth/parameters/disable_ertm ]] && [[ "$(cat /sys/module/bluetooth/parameters/disable_ertm 2>/dev/null)" != "Y" ]]; then
    PI5_BLUETOOTH_MODPROBE_NEEDS_REBOOT=1
    log "Bluetooth module loaded without disable_ertm=Y; reboot to apply ${bluetooth_dst}"
  fi
}

compose_has_service() {
  local svc="$1"
  docker compose config --services 2>/dev/null | grep -qx "${svc}"
}

compose_service_running() {
  local svc="$1"
  docker compose ps --status running --services 2>/dev/null | grep -qx "${svc}"
}

add_aliases() {
  local user_name user_home bashrc alias_block
  user_name="${SUDO_USER:-root}"
  user_home="$(getent passwd "${user_name}" | cut -d: -f6)"
  bashrc="${user_home}/.bashrc"

  alias_block=$'# Homelab\nalias hl='\''cd /opt/homelab'\''\nalias hlstatus='\''/opt/homelab/scripts/status.sh'\''\nalias hllogs='\''/opt/homelab/scripts/logs.sh'\''\nalias hlupdate='\''/opt/homelab/scripts/update.sh'\''\nalias hlbackup='\''/opt/homelab/scripts/backup.sh'\''\nalias hltest='\''/opt/homelab/scripts/test.sh'\'''

  if [[ -f "${bashrc}" ]] && grep -qF "alias hl='cd /opt/homelab'" "${bashrc}"; then
    log "Aliases already present in ${bashrc}"
  else
    printf "\n%s\n" "${alias_block}" >>"${bashrc}"
    log "Added homelab aliases to ${bashrc}"
  fi
}

compose_up() {
  log "Starting containers"
  cd "${BASE_DIR}"
  docker compose up -d
}

MONITORING_SERVICES=(prometheus grafana node-exporter cadvisor smartctl-exporter)

compose_monitoring_install() {
  local did_full_stack_recreate="${1:-0}"
  local svc missing=() needs_build=0

  cd "${BASE_DIR}"

  if ! compose_has_service "prometheus"; then
    log "docker-compose.yml has no prometheus service. Refresh templates (e.g. sudo ./bootstrap/setup.sh --install --force)."
    return 0
  fi

  if [[ "${did_full_stack_recreate}" -eq 1 ]]; then
    log "Monitoring stack already recreated with full stack (--clean-install)."
    return 0
  fi

  for svc in "${MONITORING_SERVICES[@]}"; do
    if ! compose_has_service "${svc}"; then
      continue
    fi
    if ! compose_service_running "${svc}"; then
      missing+=("${svc}")
      if [[ "${svc}" == "smartctl-exporter" ]]; then
        needs_build=1
      fi
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    log "Monitoring stack already running; skipping redeploy (use --clean-install to recreate the full stack, including monitoring)."
    return 0
  fi

  log "Deploying monitoring services: ${missing[*]}"
  if [[ "${needs_build}" -eq 1 ]]; then
    docker compose up -d --build "${missing[@]}"
  else
    docker compose up -d "${missing[@]}"
  fi
}

compose_install() {
  local did_full_stack_recreate=0

  cd "${BASE_DIR}"

  if docker compose ps -a --services 2>/dev/null | grep -q .; then
    if [[ "${CLEAN_INSTALL}" -eq 1 ]]; then
      log "Existing containers detected. Recreating because --clean-install was set."
      docker compose up -d --force-recreate
      did_full_stack_recreate=1
    else
      log "Existing containers detected. Skipping container creation (use --clean-install to recreate)."
    fi
  else
    compose_up
  fi

  compose_monitoring_install "${did_full_stack_recreate}"
}

do_install() {
  require_root
  resolve_host
  install_host_tools
  configure_nvme_power
  configure_pi5_wifi_bt_stability
  install_neovim_latest_stable
  install_docker_if_missing
  create_structure
  fix_grafana_permissions
  populate_templates
  add_aliases
  compose_install

  cat <<EOF

Homelab bootstrap complete.

Repo:           ${REPO_ROOT}
Host profile:   ${HOST:-none}
Base directory: ${BASE_DIR}
Edit env:       ${BASE_DIR}/.env  (or hosts/${HOST}/host.env + secrets.env)
Stack status:   ${BASE_DIR}/scripts/status.sh
Health checks:  ${BASE_DIR}/scripts/test.sh  (alias: hltest)
Monitoring:     Prometheus :9090, Grafana :3002, cAdvisor :8082, smartctl :9633

Potential reboot needed for docker group changes:
  sudo reboot
EOF
  if [[ "${NVME_CMDLINE_NEEDS_REBOOT}" -eq 1 ]]; then
    echo "NVMe: reboot once to apply nvme_core.default_ps_max_latency_us=0 in cmdline."
  fi
  if [[ "${PI5_BLUETOOTH_MODPROBE_NEEDS_REBOOT}" -eq 1 ]]; then
    echo "Pi 5 Bluetooth: reboot once so disable_ertm=Y is applied (/etc/modprobe.d/99-homelab-bluetooth-disable-ertm.conf)."
  fi
}

do_update() {
  require_root
  "${BASE_DIR}/scripts/update.sh"
}

do_backup() {
  require_root
  "${BASE_DIR}/scripts/backup.sh"
}

do_restart() {
  require_root
  cd "${BASE_DIR}"
  docker compose restart
}

do_reset() {
  require_root
  read -r -p "This will delete ${BASE_DIR}. Type RESET to continue: " answer
  if [[ "${answer}" != "RESET" ]]; then
    echo "Reset cancelled."
    exit 1
  fi
  if [[ -d "${BASE_DIR}" ]]; then
    cd "${BASE_DIR}" && docker compose down || true
    rm -rf "${BASE_DIR}"
  fi
  echo "Removed ${BASE_DIR}"
}

do_test() {
  if [[ ! -x "${BASE_DIR}/scripts/test.sh" ]]; then
    echo "Test script not found. Run: sudo ./bootstrap/setup.sh --install"
    exit 1
  fi
  "${BASE_DIR}/scripts/test.sh" "${TEST_SUITE}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST="${2:-}"
      if [[ -z "${HOST}" ]]; then
        echo "--host requires a name"
        exit 1
      fi
      shift
      ;;
    --install) ACTION="install" ;;
    --update) ACTION="update" ;;
    --backup) ACTION="backup" ;;
    --restart) ACTION="restart" ;;
    --test) ACTION="test" ;;
    --test-nvme) ACTION="test"; TEST_SUITE="nvme" ;;
    --reset) ACTION="reset" ;;
    --force) FORCE=1 ;;
    --clean-install|--recreate-containers) CLEAN_INSTALL=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

case "${ACTION}" in
  install) do_install ;;
  update) do_update ;;
  backup) do_backup ;;
  restart) do_restart ;;
  reset) do_reset ;;
  test) do_test ;;
esac
