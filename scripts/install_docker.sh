#!/usr/bin/env bash
# scripts/install_docker.sh — Docker Engine from the official Docker apt repo.
# Arch-aware (dpkg --print-architecture) and distro-aware (/etc/os-release),
# so the same script works on x86_64/arm64 Ubuntu and Debian. Idempotent:
# an existing Docker install is reused and reconfigured, never duplicated.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# This script ACTS — see LCA_MAY_PROMPT in lib.sh.
LCA_MAY_PROMPT=true
load_env

install_docker_repo_and_engine() {
  net_guard "Installing Docker"

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
    | write_root_file /etc/apt/keyrings/docker.asc 0644
  as_root chmod a+r /etc/apt/keyrings/docker.asc

  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${distro_id} ${codename} stable" \
    | write_root_file /etc/apt/sources.list.d/docker.list 0644

  apt_get update -y
  apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
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

  if systemd_available && systemctl cat docker >/dev/null 2>&1; then
    as_root systemctl enable --now docker
    ok "Docker service enabled and running."
  elif ! systemd_available; then
    warn "systemd not available — cannot enable the Docker service; start dockerd yourself."
  else
    # docker present but no docker.service unit — e.g. snap-packaged Docker
    # (snap.docker.dockerd.service) or a rootless install. Don't try to
    # enable a unit that doesn't exist; just confirm the daemon answers.
    warn "No 'docker.service' systemd unit (externally managed Docker, e.g. snap/rootless) — reusing it as-is."
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

  # The smoke test needs a running daemon. If none is reachable (e.g. no
  # init system started dockerd), warn and continue rather than crash the
  # whole setup — the rest of the stack (Ollama, aider) does not need Docker.
  #
  # lib.sh's docker_daemon_reachable, not a local copy. The copy that lived
  # here was one line and one guard short: it fell straight through to
  # 'as_root docker info', and as_root DIES when there is neither root nor
  # sudo. So on the one host shape this branch exists for — no init system,
  # daemon down — a passwordless-sudo-less user got "Root privileges needed
  # for: docker info" and setup stopped, instead of the warning below and a
  # stack that carries on without Docker.
  if ! docker_daemon_reachable; then
    warn "Docker daemon is not running (no init system started it?) — start it, then re-run ${REPO_ROOT}/scripts/install_webui.sh. Skipping the smoke test."
    return 0
  fi

  info "Running the hello-world smoke test..."
  if as_root docker run --rm hello-world >/dev/null 2>&1; then
    ok "Docker can run containers."
  else
    if [[ "$(netmode_state)" == "offline" ]]; then
      warn "Smoke test skipped/failed — netmode is offline, so the hello-world image cannot be pulled. Docker itself looks installed."
    else
      die "Docker hello-world failed. Inspect the daemon with: sudo systemctl status docker (or 'docker info')"
    fi
  fi
}

main "$@"
