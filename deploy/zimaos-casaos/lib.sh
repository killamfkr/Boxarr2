#!/usr/bin/env bash
# Shared Docker Compose detection for CasaOS / ZimaOS install scripts.
# Sets BOXARR_COMPOSE as a bash array, e.g. (docker compose) or (sudo docker-compose).

boxarr_detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    BOXARR_COMPOSE=(docker compose)
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 && sudo docker compose version >/dev/null 2>&1; then
    BOXARR_COMPOSE=(sudo docker compose)
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
    BOXARR_COMPOSE=(docker-compose)
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 && command -v docker-compose >/dev/null 2>&1 && sudo docker-compose version >/dev/null 2>&1; then
    BOXARR_COMPOSE=(sudo docker-compose)
    return 0
  fi
  return 1
}

boxarr_install_compose_plugin() {
  local s="${SUDO:-}"
  if command -v apt-get >/dev/null 2>&1; then
    $s apt-get update -qq
    if $s apt-get install -y docker-compose-plugin 2>/dev/null; then
      return 0
    fi
    if $s apt-get install -y docker-compose 2>/dev/null; then
      return 0
    fi
  fi
  if command -v apk >/dev/null 2>&1; then
    $s apk add --no-cache docker-cli-compose 2>/dev/null && return 0
  fi
  if command -v pacman >/dev/null 2>&1; then
    $s pacman -Sy --noconfirm docker-compose 2>/dev/null && return 0
  fi
  return 1
}

# Detect compose, optionally install, die with help text on failure.
boxarr_ensure_compose() {
  local log_fn="${1:-true}"
  if boxarr_detect_compose; then
    $log_fn "Using Docker Compose: ${BOXARR_COMPOSE[*]}"
    return 0
  fi
  $log_fn "Docker Compose not found — attempting to install..."
  boxarr_install_compose_plugin || true
  if boxarr_detect_compose; then
    $log_fn "Using Docker Compose: ${BOXARR_COMPOSE[*]}"
    return 0
  fi
  return 1
}

boxarr_compose_die_help() {
  cat <<EOF >&2
Docker Compose is required but was not found.

Tried: docker compose, sudo docker compose, docker-compose, sudo docker-compose

On CasaOS / ZimaOS, install the Compose plugin over SSH:

  sudo apt-get update
  sudo apt-get install -y docker-compose-plugin

Then verify:

  docker compose version
  # or, if your user is not in the docker group yet:
  sudo docker compose version

If docker works only with sudo, re-run this installer with sudo:

  sudo bash install.sh

To avoid sudo for docker permanently, add your user to the docker group
(log out and back in afterward):

  sudo usermod -aG docker "\$USER"
EOF
}

# Run compose with env file, compose file, optional profiles, and extra args.
boxarr_compose() {
  local env_file="$1" compose_file="$2"
  shift 2
  local profiles=()
  if [[ "${RCLONE_MODE:-host}" == "docker" ]]; then
    profiles+=(--profile docker-rclone)
  fi
  if [[ "${WITH_SEERR:-true}" == "true" ]]; then
    profiles+=(--profile seerr)
  fi
  "${BOXARR_COMPOSE[@]}" --env-file "${env_file}" -f "${compose_file}" "${profiles[@]}" "$@"
}
