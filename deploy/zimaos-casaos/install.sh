#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Boxarr installer for CasaOS / ZimaOS (and generic Linux with /DATA or /mnt)
#
# Recommended: host rclone (systemd) + Boxarr in Docker via compose over SSH.
# Do NOT rely on the CasaOS/ZimaOS app GUI for this stack — it drops mount flags.
#
# Quick start (after cloning the repo):
#   sudo bash deploy/zimaos-casaos/install.sh
#
# One-liner (API key only — recommended):
#   TORBOX_API_KEY=your-api-key \
#     curl -fsSL https://cdn.jsdelivr.net/gh/killamfkr/Boxarr2@main/deploy/zimaos-casaos/install.sh | sudo -E bash -s -- -y
#
# Interactive (recommended over SSH — download first so prompts work):
#   curl -fsSL https://cdn.jsdelivr.net/gh/killamfkr/Boxarr2@main/deploy/zimaos-casaos/install.sh -o /tmp/boxarr-install.sh
#   chmod +x /tmp/boxarr-install.sh && sudo /tmp/boxarr-install.sh
#
# Environment (optional):
#   BOXARR_INSTALL_DIR   default /DATA/AppData/boxarr-stack
#   BOXARR_TORBOX_MOUNT  default /DATA/torbox
#   BOXARR_LIBRARY_ROOT  default /DATA/library
#   RCLONE_MODE          host (default) or docker
#   WITH_SEERR           true (default) or false
#   PUID / PGID          default: user running the script
#   MOUNT_PROVIDER        auto (default), api, or rclone
#   TORBOX_API_KEY        torbox.app → Settings → API (enough for install)
#   TORBOX_WEBDAV_USER/PASS  only if MOUNT_PROVIDER=rclone (WebDAV mount)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

VERSION="1.1.0"
YES=false
DOCKER_RCLONE=false
NO_SEERR=false
FORCE_RCLONE_MOUNT=false
ENV_SECRETS=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[install]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[install]${NC} $*" >&2; }
die()  { echo -e "${RED}[install]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${CYAN}${BOLD}==>${NC} ${BOLD}$*${NC}" >&2; }

usage() {
  cat <<EOF
Boxarr CasaOS/ZimaOS installer v${VERSION}

Usage: install.sh [options]

Options:
  -y, --yes           Non-interactive (requires TORBOX_API_KEY or WebDAV creds)
  --env-file PATH     Load secrets (TORBOX_API_KEY, etc.) from a file
  --rclone-mount      Use rclone WebDAV instead of API-key mount (needs email+password)
  --docker-rclone     Run rclone inside Docker instead of on the host (less reliable)
  --no-seerr          Skip the Seerr container
  -h, --help          Show this help

By default only your TorBox API key is required. The installer mounts TorBox via
the torbox-media-center container. Use --rclone-mount for classic WebDAV+rclone.

Docs: deploy/zimaos-casaos/README.md
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) YES=true; shift ;;
    --env-file)
      [[ $# -ge 2 ]] || die "--env-file requires a path"
      ENV_SECRETS="$2"
      shift 2
      ;;
    --docker-rclone) DOCKER_RCLONE=true; shift ;;
    --rclone-mount) FORCE_RCLONE_MOUNT=true; shift ;;
    --no-seerr) NO_SEERR=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

if [[ -n "${ENV_SECRETS}" ]]; then
  [[ -f "${ENV_SECRETS}" ]] || die "--env-file not found: ${ENV_SECRETS}"
  # shellcheck disable=SC1090
  source "${ENV_SECRETS}"
fi

# ── Locate bundled templates ─────────────────────────────────────────────────
resolve_bundle_dir() {
  if [[ -n "${BOXARR_BUNDLE_DIR:-}" && -d "${BOXARR_BUNDLE_DIR}" ]]; then
    echo "${BOXARR_BUNDLE_DIR}"
    return
  fi
  local src="${BASH_SOURCE[0]}"
  if [[ -f "$src" && "$src" != /dev/fd/* && "$src" != /proc/* ]]; then
    local dir
    dir="$(cd "$(dirname "$src")" && pwd)"
    if [[ -f "${dir}/docker-compose.yml" ]]; then
      echo "$dir"
      return
    fi
  fi
  local tmp base
  tmp="$(mktemp -d /tmp/boxarr-bundle.XXXXXX)"
  base="${BOXARR_RAW_BASE:-https://cdn.jsdelivr.net/gh/killamfkr/Boxarr2@main/deploy/zimaos-casaos}"
  log "Downloading install bundle from ${base}..."
  for f in docker-compose.yml env.example manage.sh rclone-torbox.service lib.sh; do
    curl -fsSL "${base}/${f}" -o "${tmp}/${f}" || die "Failed to download ${base}/${f}"
  done
  echo "$tmp"
}

BUNDLE_DIR="$(resolve_bundle_dir)"

# ── Defaults tuned for CasaOS / ZimaOS ───────────────────────────────────────
PUID="${PUID:-$(id -u)}"
PGID="${PGID:-$(id -g)}"
INSTALL_DIR="${BOXARR_INSTALL_DIR:-/DATA/AppData/boxarr-stack}"
TORBOX_MOUNT="${BOXARR_TORBOX_MOUNT:-/DATA/torbox}"
LIBRARY_ROOT="${BOXARR_LIBRARY_ROOT:-/DATA/library}"
RCLONE_MODE="${RCLONE_MODE:-host}"
WITH_SEERR="${WITH_SEERR:-true}"
TZ="${TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
BOXARR_PORT="${BOXARR_PORT:-8181}"
SEERR_PORT="${SEERR_PORT:-5055}"
RCLONE_REMOTE="${RCLONE_REMOTE:-torbox}"
BOXARR_IMAGE="${BOXARR_IMAGE:-ghcr.io/radaiko/boxarr:latest}"
MOUNT_PROVIDER="${MOUNT_PROVIDER:-auto}"
TORBOX_API_KEY="${TORBOX_API_KEY:-}"
TORBOX_WEBDAV_USER="${TORBOX_WEBDAV_USER:-}"
TORBOX_WEBDAV_PASS="${TORBOX_WEBDAV_PASS:-}"

if $FORCE_RCLONE_MOUNT; then
  MOUNT_PROVIDER=rclone
fi

if $DOCKER_RCLONE; then
  RCLONE_MODE=docker
fi
if $NO_SEERR; then
  WITH_SEERR=false
fi

ENV_FILE="${INSTALL_DIR}/.env"
RCLONE_DIR="${INSTALL_DIR}/rclone"
RCLONE_CONFIG="${RCLONE_DIR}/rclone.conf"
RCLONE_CACHE="${RCLONE_DIR}/cache"
COMPOSE_DST="${INSTALL_DIR}/docker-compose.yml"
MANAGE_DST="${INSTALL_DIR}/manage.sh"

prompt() {
  local var="$1" prompt_text="$2" default="${3:-}" secret="${4:-false}"
  if $YES; then
    if [[ -z "${!var:-}" ]]; then
      if [[ -n "$default" ]]; then
        printf -v "$var" '%s' "$default"
      else
        die "Non-interactive mode requires ${var} to be set."
      fi
    fi
    return
  fi
  if [[ ! -t 0 ]]; then
    boxarr_mount_creds_die_help
    exit 1
  fi
  local input
  if [[ "$secret" == "true" ]]; then
    read -rsp "${prompt_text}${default:+ [$default]}: " input
    echo "" >&2
  else
    read -rp "${prompt_text}${default:+ [$default]}: " input
  fi
  if [[ -z "$input" && -n "$default" ]]; then
    input="$default"
  fi
  printf -v "$var" '%s' "$input"
}

webdav_creds_ready() {
  [[ -f "${RCLONE_CONFIG}" ]] && grep -q "^\[${RCLONE_REMOTE}\]" "${RCLONE_CONFIG}" && return 0
  [[ -n "${TORBOX_WEBDAV_USER}" && -n "${TORBOX_WEBDAV_PASS}" ]] && return 0
  return 1
}

resolve_mount_provider() {
  case "${MOUNT_PROVIDER}" in
    api)
      [[ -n "${TORBOX_API_KEY}" ]] && echo api && return 0
      echo ""
      return 0
      ;;
    rclone)
      webdav_creds_ready && echo rclone && return 0
      echo ""
      return 0
      ;;
    auto)
      if [[ -n "${TORBOX_API_KEY}" ]]; then
        echo api
        return 0
      fi
      if webdav_creds_ready; then
        echo rclone
        return 0
      fi
      echo ""
      return 0
      ;;
    *)
      die "Invalid MOUNT_PROVIDER=${MOUNT_PROVIDER} (use auto, api, or rclone)"
      ;;
  esac
}

boxarr_mount_creds_die_help() {
  cat <<'EOF' >&2

A TorBox API key is required (torbox.app → Settings → API).

If you used  curl ... | bash , pass the key on the same line (sudo -E keeps env vars):

  TORBOX_API_KEY='your-api-key' \
    curl -fsSL https://cdn.jsdelivr.net/gh/killamfkr/Boxarr2@main/deploy/zimaos-casaos/install.sh \
    | sudo -E bash -s -- -y

Or download first for an interactive prompt (recommended):

  curl -fsSL https://cdn.jsdelivr.net/gh/killamfkr/Boxarr2@main/deploy/zimaos-casaos/install.sh -o /tmp/boxarr-install.sh
  chmod +x /tmp/boxarr-install.sh
  sudo /tmp/boxarr-install.sh

Secrets file:

  printf 'TORBOX_API_KEY=your-api-key\n' > /tmp/boxarr.env
  chmod 600 /tmp/boxarr.env
  sudo /tmp/boxarr-install.sh --env-file /tmp/boxarr.env -y

To use rclone WebDAV instead (email + password, not API key), add --rclone-mount:

  TORBOX_WEBDAV_USER='your@email.com' TORBOX_WEBDAV_PASS='your-password' \
    sudo /tmp/boxarr-install.sh --rclone-mount -y
EOF
}

boxarr_webdav_creds_die_help() {
  cat <<'EOF' >&2

rclone WebDAV mount requires your torbox.app email + password (not the API key).

Either pass WebDAV credentials with --rclone-mount, or omit --rclone-mount and use
TORBOX_API_KEY only (recommended).
EOF
  boxarr_mount_creds_die_help
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

if [[ "$(id -u)" -ne 0 ]]; then
  warn "Not running as root — will use sudo for systemd, FUSE, and directory setup."
  SUDO="sudo"
else
  SUDO=""
fi

step "Preflight checks"
need_cmd docker
need_cmd curl
# shellcheck source=lib.sh
source "${BUNDLE_DIR}/lib.sh"
if ! boxarr_ensure_compose log; then
  boxarr_compose_die_help
  exit 1
fi

if [[ -d /DATA ]]; then
  log "Detected /DATA — using CasaOS/ZimaOS style paths."
elif [[ ! -d "$(dirname "$INSTALL_DIR")" ]]; then
  warn "/DATA not found; falling back to \$HOME/boxarr-stack"
  INSTALL_DIR="${BOXARR_INSTALL_DIR:-$HOME/boxarr-stack}"
  TORBOX_MOUNT="${BOXARR_TORBOX_MOUNT:-$HOME/boxarr-stack/torbox}"
  LIBRARY_ROOT="${BOXARR_LIBRARY_ROOT:-$HOME/boxarr-stack/library}"
  ENV_FILE="${INSTALL_DIR}/.env"
  RCLONE_DIR="${INSTALL_DIR}/rclone"
  RCLONE_CONFIG="${RCLONE_DIR}/rclone.conf"
  RCLONE_CACHE="${RCLONE_DIR}/cache"
  COMPOSE_DST="${INSTALL_DIR}/docker-compose.yml"
  MANAGE_DST="${INSTALL_DIR}/manage.sh"
fi

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

step "TorBox credentials"
if [[ -z "${TORBOX_API_KEY}" ]]; then
  if $YES || [[ ! -t 0 ]]; then
    if ! webdav_creds_ready && [[ "${MOUNT_PROVIDER}" != "rclone" ]]; then
      boxarr_mount_creds_die_help
      exit 1
    fi
  else
    prompt TORBOX_API_KEY "TorBox API key (torbox.app → Settings → API)" "" true
  fi
fi

MOUNT_PROVIDER="$(resolve_mount_provider)"
if [[ -z "${MOUNT_PROVIDER}" ]]; then
  if $YES || [[ ! -t 0 ]]; then
    boxarr_mount_creds_die_help
    exit 1
  fi
  die "Could not determine mount method — set TORBOX_API_KEY or WebDAV credentials."
fi
log "Mount method: ${MOUNT_PROVIDER}"

step "Creating directories"
dirs=(
  "${INSTALL_DIR}/config"
  "${INSTALL_DIR}/seerr"
  "${RCLONE_DIR}"
  "${RCLONE_CACHE}"
  "${TORBOX_MOUNT}"
  "${LIBRARY_ROOT}/movies"
  "${LIBRARY_ROOT}/tv"
  "${LIBRARY_ROOT}/anime"
)
for d in "${dirs[@]}"; do
  $SUDO mkdir -p "$d"
done
$SUDO chown -R "${PUID}:${PGID}" "${INSTALL_DIR}" "${TORBOX_MOUNT}" "${LIBRARY_ROOT}"

step "FUSE prerequisites"
if [[ ! -e /dev/fuse ]]; then
  $SUDO modprobe fuse 2>/dev/null || true
fi
if [[ ! -e /dev/fuse ]]; then
  die "/dev/fuse not available. Install fuse3 on the host and re-run."
fi
if [[ -f /etc/fuse.conf ]] && ! grep -q '^user_allow_other' /etc/fuse.conf; then
  log "Enabling user_allow_other in /etc/fuse.conf"
  echo 'user_allow_other' | $SUDO tee -a /etc/fuse.conf >/dev/null
fi

install_rclone() {
  if command -v rclone >/dev/null 2>&1; then
    return
  fi
  log "Installing rclone..."
  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq rclone fuse3
  else
    curl -fsSL https://rclone.org/install.sh | $SUDO bash
  fi
  command -v rclone >/dev/null 2>&1 || die "rclone installation failed"
}

RCLONE_BIN="$(command -v rclone || true)"
if [[ "${MOUNT_PROVIDER}" == "rclone" && "${RCLONE_MODE}" == "host" ]]; then
  install_rclone
  RCLONE_BIN="$(command -v rclone)"
fi

write_rclone_config() {
  local user="$1" pass="$2"
  local obscured
  obscured="$("${RCLONE_BIN}" obscure "${pass}")"
  cat >"${RCLONE_CONFIG}" <<EOF
[${RCLONE_REMOTE}]
type = webdav
url = https://webdav.torbox.app
vendor = other
user = ${user}
pass = ${obscured}
EOF
  chmod 600 "${RCLONE_CONFIG}"
}

if [[ "${MOUNT_PROVIDER}" == "rclone" ]]; then
  step "TorBox WebDAV / rclone configuration"
  if webdav_creds_ready && [[ -f "${RCLONE_CONFIG}" ]] && grep -q "^\[${RCLONE_REMOTE}\]" "${RCLONE_CONFIG}"; then
    log "Using existing ${RCLONE_CONFIG}"
  else
    if [[ -z "${TORBOX_WEBDAV_USER}" || -z "${TORBOX_WEBDAV_PASS}" ]]; then
      echo "" >&2
      warn "rclone WebDAV needs your torbox.app email + password (not the API key)."
      warn "See: https://support.torbox.app/en/articles/14662867-torbox-webdav"
      echo "" >&2
      prompt TORBOX_WEBDAV_USER "TorBox WebDAV username (email)"
      prompt TORBOX_WEBDAV_PASS "TorBox WebDAV password" "" true
    fi
    [[ -n "${TORBOX_WEBDAV_USER}" && -n "${TORBOX_WEBDAV_PASS}" ]] || {
      boxarr_webdav_creds_die_help
      exit 1
    }
    write_rclone_config "${TORBOX_WEBDAV_USER}" "${TORBOX_WEBDAV_PASS}"
    log "Wrote ${RCLONE_CONFIG}"
  fi
else
  step "TorBox API mount"
  log "Using API-key mount (torbox-media-center) — no WebDAV username/password needed."
fi

step "Writing ${ENV_FILE}"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  PUID="${PUID:-$(id -u)}"
  PGID="${PGID:-$(id -g)}"
  INSTALL_DIR="${BOXARR_INSTALL_DIR:-${INSTALL_DIR}}"
  TORBOX_MOUNT="${BOXARR_TORBOX_MOUNT:-${TORBOX_MOUNT}}"
  LIBRARY_ROOT="${BOXARR_LIBRARY_ROOT:-${LIBRARY_ROOT}}"
  RCLONE_MODE="${RCLONE_MODE:-host}"
  WITH_SEERR="${WITH_SEERR:-true}"
  TZ="${TZ:-UTC}"
  BOXARR_PORT="${BOXARR_PORT:-8181}"
  SEERR_PORT="${SEERR_PORT:-5055}"
  RCLONE_REMOTE="${RCLONE_REMOTE:-torbox}"
  BOXARR_IMAGE="${BOXARR_IMAGE:-ghcr.io/radaiko/boxarr:latest}"
  MOUNT_PROVIDER="${MOUNT_PROVIDER:-auto}"
  TORBOX_API_KEY="${TORBOX_API_KEY:-}"
  TORBOX_WEBDAV_USER="${TORBOX_WEBDAV_USER:-}"
  TORBOX_WEBDAV_PASS="${TORBOX_WEBDAV_PASS:-}"
fi
MOUNT_PROVIDER="$(resolve_mount_provider)"
if [[ -f "${ENV_FILE}" ]] && ! $YES; then
  warn "${ENV_FILE} already exists — updating paths and preserving unset secrets."
fi
{
  echo "# Boxarr stack — managed by install.sh v${VERSION}"
  echo "BOXARR_INSTALL_DIR=${INSTALL_DIR}"
  echo "BOXARR_TORBOX_MOUNT=${TORBOX_MOUNT}"
  echo "BOXARR_LIBRARY_ROOT=${LIBRARY_ROOT}"
  echo "PUID=${PUID}"
  echo "PGID=${PGID}"
  echo "TZ=${TZ}"
  echo "RCLONE_REMOTE=${RCLONE_REMOTE}"
  echo "RCLONE_MODE=${RCLONE_MODE}"
  echo "MOUNT_PROVIDER=${MOUNT_PROVIDER}"
  echo "WITH_SEERR=${WITH_SEERR}"
  echo "BOXARR_PORT=${BOXARR_PORT}"
  echo "SEERR_PORT=${SEERR_PORT}"
  echo "BOXARR_IMAGE=${BOXARR_IMAGE}"
  echo "TORBOX_WEBDAV_USER=${TORBOX_WEBDAV_USER:-}"
  echo "TORBOX_WEBDAV_PASS=${TORBOX_WEBDAV_PASS:-}"
  echo "TORBOX_API_KEY=${TORBOX_API_KEY:-}"
  echo "PROWLARR_URL=${PROWLARR_URL:-http://host.docker.internal:9696}"
  echo "PROWLARR_API_KEY=${PROWLARR_API_KEY:-}"
  echo "TMDB_API_KEY=${TMDB_API_KEY:-}"
  echo "BOXARR_SEERR_API_KEY=${BOXARR_SEERR_API_KEY:-}"
} >"${ENV_FILE}"
chmod 600 "${ENV_FILE}"

step "Installing docker-compose.yml, lib.sh, and manage.sh"
cp "${BUNDLE_DIR}/docker-compose.yml" "${COMPOSE_DST}"
cp "${BUNDLE_DIR}/lib.sh" "${INSTALL_DIR}/lib.sh"
cp "${BUNDLE_DIR}/manage.sh" "${MANAGE_DST}"
chmod +x "${MANAGE_DST}"

if [[ "${MOUNT_PROVIDER}" == "rclone" && "${RCLONE_MODE}" == "host" ]]; then
  step "Installing systemd unit: boxarr-rclone.service"
  if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    sed \
      -e "s|__ENV_FILE__|${ENV_FILE}|g" \
      -e "s|__PUID__|${PUID}|g" \
      -e "s|__PGID__|${PGID}|g" \
      -e "s|__TORBOX_MOUNT__|${TORBOX_MOUNT}|g" \
      -e "s|__RCLONE_BIN__|${RCLONE_BIN}|g" \
      -e "s|__RCLONE_REMOTE__|${RCLONE_REMOTE}|g" \
      -e "s|__RCLONE_CONFIG__|${RCLONE_CONFIG}|g" \
      -e "s|__RCLONE_CACHE__|${RCLONE_CACHE}|g" \
      "${BUNDLE_DIR}/rclone-torbox.service" | $SUDO tee /etc/systemd/system/boxarr-rclone.service >/dev/null
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable boxarr-rclone.service
    log "Starting boxarr-rclone.service..."
    $SUDO systemctl restart boxarr-rclone.service
    sleep 3
    if mountpoint -q "${TORBOX_MOUNT}"; then
      log "TorBox mount is active at ${TORBOX_MOUNT}"
    else
      warn "TorBox mount not active yet. Check: sudo journalctl -u boxarr-rclone -n 50"
    fi
  else
    warn "systemd not found — start rclone manually before Boxarr."
  fi
else
  if [[ "${MOUNT_PROVIDER}" == "api" ]]; then
    log "TorBox mount will run in the torbox-media-center container."
  else
    warn "Docker rclone mode: ensure the CasaOS/ZimaOS GUI does not manage this stack."
  fi
fi

step "Starting Boxarr stack"
export BOXARR_INSTALL_DIR="${INSTALL_DIR}"
export BOXARR_TORBOX_MOUNT="${TORBOX_MOUNT}"
export BOXARR_LIBRARY_ROOT="${LIBRARY_ROOT}"
"${MANAGE_DST}" pull || true
"${MANAGE_DST}" start

ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
ip="${ip:-<host-ip>}"

cat <<EOF

${GREEN}${BOLD}Boxarr install complete${NC}

${BOLD}Open Boxarr:${NC}  http://${ip}:${BOXARR_PORT}
$( [[ "${WITH_SEERR}" == "true" ]] && echo "${BOLD}Open Seerr:${NC}   http://${ip}:${SEERR_PORT}" )

${BOLD}Manage:${NC}  cd ${INSTALL_DIR} && ./manage.sh <start|stop|restart|logs|health|mount>

${BOLD}Finish setup in Boxarr UI → Settings:${NC}
  • Prowlarr URL + API key
  • TMDB Read Access Token (v4)
  • Plex (Sign in with Plex, or set URL + token)
  $( [[ -n "${TORBOX_API_KEY}" ]] && echo "• TorBox API token is pre-seeded from install" )

${BOLD}Plex containers must bind-mount BOTH paths at the same absolute path:${NC}
  • ${LIBRARY_ROOT} → ${LIBRARY_ROOT}
  • ${TORBOX_MOUNT} → ${TORBOX_MOUNT}  (propagation: rslave if your compose editor supports it)

${BOLD}Seerr (optional):${NC} add Sonarr/Radarr pointing at http://boxarr:8080/sonarr and /radarr
  (generate the Seerr API key in Boxarr → Settings → Requests)

${YELLOW}Important:${NC} Deploy and update this stack via SSH + ./manage.sh — not the CasaOS/ZimaOS
app GUI, which drops bind-mount propagation flags Plex needs after rclone restarts.

EOF
