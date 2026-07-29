#!/usr/bin/env bash
# scripts/install_git.sh — ensure git is present and sanely configured.
# Aider auto-commits its edits, so a git identity matters; we warn (not die)
# because unattended first boots have no user to answer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

main() {
  step "Checking git"
  if ! have git; then
    net_guard "Installing git"
    apt_get install -y git
  fi
  require_cmd git
  ok "git $(git --version | awk '{print $3}') installed."

  # When run via sudo, check the real user's global config, not root's.
  local check_user name email
  check_user="${SUDO_USER:-$(id -un)}"
  if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" ]] && have sudo; then
    name="$(sudo -u "${check_user}" git config --global user.name 2>/dev/null || true)"
    email="$(sudo -u "${check_user}" git config --global user.email 2>/dev/null || true)"
  else
    name="$(git config --global user.name 2>/dev/null || true)"
    email="$(git config --global user.email 2>/dev/null || true)"
  fi
  if [[ -z "${name}" || -z "${email}" ]]; then
    warn "No global git identity set for '${check_user}'. Aider's auto-commits will use a default identity."
    warn "Set one with:  git config --global user.name 'Your Name' && git config --global user.email 'you@example.com'"
  else
    ok "git identity: ${name} <${email}>"
  fi
}

main "$@"
