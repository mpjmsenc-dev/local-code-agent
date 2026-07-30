#!/usr/bin/env bash
# scripts/install_dependencies.sh — base OS packages for local-code-agent.
# Idempotent: apt only installs what is missing; verification runs every time.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

# Cloud images and CI runners preinstall many of these; minimal Ubuntu/Debian
# do NOT, so install them explicitly (install_dependencies runs first):
#   ca-certificates — TLS trust store; without it every HTTPS download (Docker
#                     key, ollama/tailscale installers, pip, model pulls) fails
#   zstd            — the official Ollama installer needs it to unpack
#   iproute2 (ss)   — install_webui's port-collision safety check needs it
#   python3-dev     — source builds of aider deps on arch's without wheels (arm64)
#   qrencode        — 'lca chat' prints a QR of the phone URL, so nobody has to
#                     type a Tailscale IP into a phone browser by hand
PACKAGES=(ca-certificates curl wget git python3 python3-venv python3-pip python3-dev build-essential jq unzip zip zstd iproute2 htop tree nftables qrencode)

main() {
  step "Installing base dependencies"
  require_cmd apt-get
  net_guard "Installing OS packages"

  info "Updating package lists (apt update)..."
  # apt_get waits out the apt-daily/unattended-upgrades dpkg lock (common in
  # the first minutes of a fresh boot) instead of failing the whole install.
  if ! apt_get update -y; then
    die "apt update failed. Another apt/dpkg process held the lock past the timeout (see docs/TROUBLESHOOTING.md) or the network is down."
  fi

  info "Upgrading installed packages (apt upgrade)..."
  apt_get upgrade -y

  info "Installing: ${PACKAGES[*]}"
  apt_get install -y "${PACKAGES[@]}"

  local pkg missing=0
  for pkg in "${PACKAGES[@]}"; do
    if dpkg -s "${pkg}" >/dev/null 2>&1; then
      ok "package ${pkg}"
    else
      err "package ${pkg} did not install"
      missing=$((missing+1))
    fi
  done
  if (( missing > 0 )); then
    die "${missing} package(s) failed to install — see errors above."
  fi
  ok "All base dependencies installed."
}

main "$@"
