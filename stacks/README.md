# Compose projects deployed by bootstrap/setup.sh.

# Live copies:
#   core     → /opt/homelab/docker-compose.yml
#   others   → /opt/homelab/stacks/<name>/
#
# Persistent data stays under /opt/<service>/ (or existing /opt/homelab/configs).
# Edit files here, then: sudo ./bootstrap/setup.sh --sync
#
# Portainer is view-only. If old Portainer stack names (immich, nginx-proxy-manager,
# gittea) still appear in the UI, do not click Remove unless you are sure it will
# not run `compose down` on the live git-managed project. Git compose is what
# starts these containers now.
