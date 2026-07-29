#!/usr/bin/env bash
# scripts/install_docker.sh — Docker Engine from the official Docker apt repo.
# Arch-aware (dpkg --print-architecture) and distro-aware (/etc/os-release),
# so the same script works on x86_64/arm64 Ubuntu and Debian. Idempotent:
# an existing Docker install is reused and reconfigured, never duplicated.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

install_docker_repo_and_engine() {
  net_guard "Installing Docker"
  export DEBIAN_FRONTEND=noninteractive

  info "Setting up the official Docker apt repository..."
  as_root install -m 0755 -d /etc/apt/keyrings

  local distro_id codename arch
  distro_id="$(. /etc/os-release && echo "${ID}")"
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  arch="$(dpkg --print-architecture)"
  case "${distro_id}" in
    ubuntu|debian) ;;
    *) die "Unsupported distro '${distro_id}' — this script supports Ubuntu and Debian." ;;
  esac

  curl -fsSL "https://download.docker.com/linux/${distro_id}/gpg" \
    | as_root tee /etc/apt/keyrings/docker.asc >/dev/null
  as_root chmod a+r /etc/apt/keyrings/docker.asc

  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${distro_id} ${codename} stable" \
    | as_root tee /etc/apt/sources.list.d/docker.list >/dev/null

  as_root apt-get update -y
  as_root apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

main() {
  step "Installing Docker"
  if [[ "${SKIP_DOCKER}" == "true" ]]; then
    warn "SKIP_DOCKER=true — skipping Docker (Open WebUI will not be available)."
    exit 0
  fi

  if have docker; then
    info "Docker already installed ($(docker --version)) — reusing it."
  else
    install_docker_repo_and_engine
    ok "Docker Engine installed."
  fi
  require_cmd docker

  if systemd_available; then
    as_root systemctl enable --now docker
    ok "Docker service enabled and running."
  else
    warn "systemd not available — cannot enable the Docker service; start dockerd yourself."
  fi

  # Let the invoking (non-root) user run docker without sudo.
  local docker_user="${SUDO_USER:-$(id -un)}"
  if [[ "${docker_user}" != "root" ]]; then
    if id -nG "${docker_user}" | grep -qw docker; then
      ok "User '${docker_user}' is already in the docker group."
    else
      as_root usermod -aG docker "${docker_user}"
      ok "Added '${docker_user}' to the docker group (log out/in for it to take effect)."
    fi
  fi

  info "Running the hello-world smoke test..."
  if as_root docker run --rm hello-world >/dev/null 2>&1; then
    ok "Docker can run containers."
  else
    if [[ "$(netmode_state)" == "offline" ]]; then
      warn "Smoke test skipped/failed — netmode is offline, so the hello-world image cannot be pulled. Docker itself looks installed."
    else
      die "Docker hello-world failed. Inspect the daemon with: sudo systemctl status docker"
    fi
  fi
}

main "$@"
