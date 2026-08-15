# Shared helpers for /opt/homelab scripts and bootstrap/setup.sh
HOMELAB_BASE="${HOMELAB_BASE:-/opt/homelab}"
HOMELAB_ENV="${HOMELAB_ENV:-${HOMELAB_BASE}/.env}"

homelab_stack_dirs() {
  printf '%s\n' "${HOMELAB_BASE}"
  local d
  for d in "${HOMELAB_BASE}/stacks"/*; do
    [[ -d "${d}" ]] || continue
    if [[ -f "${d}/docker-compose.yml" || -f "${d}/compose.yaml" ]]; then
      printf '%s\n' "${d}"
    fi
  done
}

homelab_compose() {
  local dir="$1"
  shift
  if [[ ! -f "${HOMELAB_ENV}" ]]; then
    echo "Missing env file: ${HOMELAB_ENV}" >&2
    return 1
  fi
  docker compose --env-file "${HOMELAB_ENV}" --project-directory "${dir}" "$@"
}

homelab_compose_all() {
  local dir
  while IFS= read -r dir; do
    echo "==> ${dir}"
    homelab_compose "${dir}" "$@"
  done < <(homelab_stack_dirs)
}
