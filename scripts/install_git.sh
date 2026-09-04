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

  # Asked through lib.sh, which also knows to look at the real user's config
  # rather than root's under sudo — 'lca check' asks the same question, and two
  # copies is how one of them ends up reporting on the wrong account.
  local check_user identity
  check_user="$(git_identity_user)"
  if identity="$(git_identity)"; then
    ok "git identity: ${identity}"
  else
    # Measured rather than assumed: aider does commit without one, using the
    # placeholder 'Your Name <you@example.com>' — but a 'git commit' the user
    # runs themselves in that project fails outright, because a hostname with
    # no domain (every fresh droplet) is not something git will guess from.
    warn "No global git identity set for '${check_user}'. Aider will still commit, stamping your work 'Your Name <you@example.com>' — and your own 'git commit' in that project will refuse to run at all."
    warn "Set one with:  git config --global user.name 'Ada Lovelace' && git config --global user.email 'ada@example.com'"
  fi
}

main "$@"
