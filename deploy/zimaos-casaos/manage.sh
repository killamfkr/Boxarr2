#!/usr/bin/env bash
# Boxarr stack management (generated beside docker-compose.yml).
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${INSTALL_DIR}/.env"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
LIB_FILE="${INSTALL_DIR}/lib.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[boxarr]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[boxarr]${NC} $*" >&2; }
die() { echo -e "${RED}[boxarr]${NC} $*" >&2; exit 1; }

[[ -f "${LIB_FILE}" ]] || die "Missing ${LIB_FILE}. Re-run install.sh."
# shellcheck source=lib.sh
source "${LIB_FILE}"
# shellcheck disable=SC1091
[[ -f "${ENV_FILE}" ]] && source "${ENV_FILE}"

: "${BOXARR_TORBOX_MOUNT:=/DATA/torbox}"
: "${RCLONE_MODE:=host}"

if ! boxarr_detect_compose; then
  boxarr_compose_die_help
  exit 1
fi

compose() {
  boxarr_compose "${ENV_FILE}" "${COMPOSE_FILE}" "$@"
}

ensure_mount_propagation() {
  if [[ ! -d "${BOXARR_TORBOX_MOUNT}" ]]; then
    warn "Mount directory missing: ${BOXARR_TORBOX_MOUNT}"
    return 0
  fi
  if mountpoint -q "${BOXARR_TORBOX_MOUNT}" 2>/dev/null; then
    return 0
  fi
  warn "TorBox mount is not active at ${BOXARR_TORBOX_MOUNT}"
  if [[ "${RCLONE_MODE}" == "host" ]]; then
    warn "Try: sudo systemctl start boxarr-rclone"
  fi
}

show_urls() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  ip="${ip:-localhost}"
  echo ""
  echo -e "${CYAN}Service URLs${NC}"
  echo "  Boxarr:  http://${ip}:${BOXARR_PORT:-8181}"
  if [[ "${WITH_SEERR:-true}" == "true" ]]; then
    echo "  Seerr:   http://${ip}:${SEERR_PORT:-5055}"
  fi
  echo ""
  echo -e "${CYAN}Plex bind mounts (same absolute paths)${NC}"
  echo "  ${BOXARR_LIBRARY_ROOT:-/DATA/library} -> ${BOXARR_LIBRARY_ROOT:-/DATA/library}"
  echo "  ${BOXARR_TORBOX_MOUNT} -> ${BOXARR_TORBOX_MOUNT}"
  echo ""
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  start       Start the stack (ensures mount propagation first)
  stop        Stop containers
  restart     Restart containers
  status      Show container status
  logs [svc]  Follow logs (optional service name)
  pull        Pull latest images
  urls        Print service URLs and Plex mount paths
  mount       Show TorBox mount status / start host rclone service
  health      Quick reachability check
  help        Show this help

Compose: ${BOXARR_COMPOSE[*]}
Install dir: ${INSTALL_DIR}
EOF
}

cmd="${1:-help}"
case "${cmd}" in
  start)
    ensure_mount_propagation
    log "Starting Boxarr stack..."
    compose up -d --remove-orphans
    show_urls
    ;;
  stop)
    compose stop
    ;;
  restart)
    ensure_mount_propagation
    compose stop
    compose up -d --remove-orphans
    show_urls
    ;;
  status)
    compose ps
    ;;
  logs)
    if [[ -n "${2:-}" ]]; then
      compose logs -f "$2"
    else
      compose logs -f
    fi
    ;;
  pull)
    compose pull
    ;;
  urls)
    show_urls
    ;;
  mount)
    if [[ "${RCLONE_MODE}" == "host" ]]; then
      if mountpoint -q "${BOXARR_TORBOX_MOUNT}" 2>/dev/null; then
        log "TorBox mount is active at ${BOXARR_TORBOX_MOUNT}"
        ls -la "${BOXARR_TORBOX_MOUNT}" | head -20
      else
        warn "TorBox mount is not active."
        if command -v systemctl >/dev/null && systemctl list-unit-files boxarr-rclone.service >/dev/null 2>&1; then
          warn "Starting boxarr-rclone.service (sudo)..."
          sudo systemctl start boxarr-rclone.service
          sleep 2
          mountpoint -q "${BOXARR_TORBOX_MOUNT}" && log "Mount is now active." || die "Mount still inactive — check: sudo journalctl -u boxarr-rclone -n 50"
        else
          die "boxarr-rclone.service not installed. Re-run install.sh."
        fi
      fi
    else
      "${BOXARR_COMPOSE[@]}" --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" --profile docker-rclone ps rclone
    fi
    ;;
  health)
    ensure_mount_propagation
    compose ps
    echo ""
    if curl -sf --connect-timeout 3 "http://127.0.0.1:${BOXARR_PORT:-8181}/healthz" >/dev/null; then
      log "Boxarr healthz: OK"
    else
      warn "Boxarr healthz: not reachable on port ${BOXARR_PORT:-8181}"
    fi
    if [[ "${WITH_SEERR:-true}" == "true" ]]; then
      if curl -sf --connect-timeout 3 "http://127.0.0.1:${SEERR_PORT:-5055}" >/dev/null; then
        log "Seerr: OK"
      else
        warn "Seerr: not reachable on port ${SEERR_PORT:-5055}"
      fi
    fi
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    die "Unknown command: ${cmd}. Run '$(basename "$0") help'."
    ;;
esac
