#!/usr/bin/env bash
# scripts/install_dependencies.sh — base OS packages for local-code-agent.
# Idempotent: apt only installs what is missing; verification runs every time.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

PACKAGES=(curl wget git python3 python3-venv python3-pip build-essential jq unzip zip htop tree nftables)

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
