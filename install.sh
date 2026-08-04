#!/usr/bin/env bash
# install.sh — one-command installer for local-code-agent on a fresh machine.
#
#   curl -fsSL https://raw.githubusercontent.com/mpjmsenc-dev/local-code-agent/main/install.sh | bash
#
# Piping anything into a shell means running code you have not read. If you
# would rather look first (recommended, and it is short):
#
#   curl -fsSL https://raw.githubusercontent.com/mpjmsenc-dev/local-code-agent/main/install.sh -o install.sh
#   less install.sh          # read it
#   bash install.sh          # then run it
#
# All this script does is install git, clone the repository, and hand over to
# setup.sh — which is the same thing docs/INSTALL.md asks you to do by hand.
#
# Environment overrides:
#   LCA_DIR=/opt/local-code-agent   where to install
#   LCA_BRANCH=main                 branch to check out
#   LCA_REPO_URL=<git url>          fork/mirror to clone from
#   LCA_RUN_SETUP=false             clone only, do not run setup.sh
set -euo pipefail

REPO_URL="${LCA_REPO_URL:-https://github.com/mpjmsenc-dev/local-code-agent.git}"
INSTALL_DIR="${LCA_DIR:-/opt/local-code-agent}"
BRANCH="${LCA_BRANCH:-main}"
RUN_SETUP="${LCA_RUN_SETUP:-true}"

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
fail() { printf '\n\033[1;31m[FAIL] %s\033[0m\n' "$*" >&2; exit 1; }

# Root without assuming sudo exists (containers often lack it) and without
# assuming we are not already root (cloud-init, Docker).
# Everything below runs inside main(), called on the very last line.
#
# This file is advertised as 'curl -fsSL ... | bash', which streams the
# script into bash and executes each statement as it arrives. A connection
# that drops part-way through would otherwise run a PARTIAL installer — far
# enough to apt-get install git and create the directory, not far enough to
# clone or hand over to setup.sh — and it would exit 0 having done so.
#
# Wrapped, a truncated download simply never reaches the call at the bottom,
# so nothing happens at all. That is the difference between a failed install
# and a half-done one nobody knows about.
main() {
  # First statement in the function, above every side effect. Asking this
  # script what it does used to be answered by installing packages and cloning
  # into ${INSTALL_DIR} — measured, not theorised: './install.sh --help' had to
  # be killed by a timeout, and left a checkout behind.
  case "${1:-}" in
    -h|--help)
      sed -n '2,/^[^#]/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
  esac
  if [[ "${EUID}" -eq 0 ]]; then
    SUDO=()
  elif command -v sudo >/dev/null 2>&1; then
    SUDO=(sudo)
  else
    fail "This installer needs root to write ${INSTALL_DIR} and install packages, but you are not root and 'sudo' is not installed. Re-run as root."
  fi

  say "local-code-agent installer"
  info "repository : ${REPO_URL} (branch ${BRANCH})"
  info "install to : ${INSTALL_DIR}"

  # --- 1. git ------------------------------------------------------------------
  if ! command -v git >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      say "Installing git"
      # DPkg::Lock::Timeout waits out apt-daily/unattended-upgrades, which
      # routinely holds the dpkg lock in the first minutes of a fresh boot.
      "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive \
        apt-get -o DPkg::Lock::Timeout=600 update -y
      "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive \
        apt-get -o DPkg::Lock::Timeout=600 install -y git ca-certificates curl
    else
      fail "git is not installed and this system has no apt-get. Install git, then re-run."
    fi
  fi

  # --- 2. clone (or update an existing checkout) --------------------------------
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    say "Updating the existing checkout in ${INSTALL_DIR}"
    "${SUDO[@]}" git -C "${INSTALL_DIR}" fetch --depth 1 origin "${BRANCH}" \
      || fail "Could not fetch ${BRANCH} from origin. Check connectivity, or that ${INSTALL_DIR} points at the right remote."
    # Hard reset rather than pull: a half-applied local edit must never leave the
    # installer wedged on a merge conflict during an unattended run.
    "${SUDO[@]}" git -C "${INSTALL_DIR}" reset --hard "origin/${BRANCH}"
  else
    say "Cloning into ${INSTALL_DIR}"
    "${SUDO[@]}" mkdir -p "$(dirname "${INSTALL_DIR}")"
    "${SUDO[@]}" git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${INSTALL_DIR}" \
      || fail "Clone failed. Check connectivity and that ${REPO_URL} is reachable."
  fi

  # A clone can succeed and still leave you without the project. Point
  # LCA_REPO_URL at the wrong fork, or LCA_BRANCH at a branch that predates the
  # code, and git exits 0 having checked out a tree with no setup.sh in it —
  # observed here by accident, cloning a stale local 'main' that held only a
  # README. Without this the installer says "Clone complete", chmod quietly
  # matches nothing, and the failure surfaces later as a confusing missing-file
  # error with no hint that the branch or URL was wrong.
  #
  # Check the outcome, not the exit status.
  [[ -f "${INSTALL_DIR}/setup.sh" ]] \
    || fail "Cloned ${REPO_URL} (branch ${BRANCH}) but it contains no setup.sh — that is not a local-code-agent checkout. Check LCA_BRANCH / LCA_REPO_URL."

  # bin/ included, like setup.sh, update.sh and deploy/do-user-data.sh: that is
  # where the 'lca' command lives. This was the only one of the four that left
  # it out, which matters exactly on the path where nothing else re-applies it —
  # LCA_RUN_SETUP=false hands over to a setup.sh the user runs by hand, on a
  # checkout made under whatever umask or filesystem dropped the bit.
  "${SUDO[@]}" chmod +x "${INSTALL_DIR}"/*.sh "${INSTALL_DIR}"/scripts/*.sh "${INSTALL_DIR}"/bin/* 2>/dev/null || true

  if [[ "${RUN_SETUP}" != "true" ]]; then
    say "Clone complete (LCA_RUN_SETUP=${RUN_SETUP} — setup was NOT run)"
    info "Run it yourself with: sudo ${INSTALL_DIR}/setup.sh"
    exit 0
  fi

  # --- 3. setup ----------------------------------------------------------------
  say "Running setup (first install downloads a model — expect 20-30 minutes)"
  # </dev/null matters: when this script is itself piped into bash, stdin is the
  # script text, and setup.sh's prompts would otherwise eat it.
  "${SUDO[@]}" "${INSTALL_DIR}/setup.sh" </dev/null

  # Deliberately NOT a second next-steps list.
  #
  # This is only reached after a setup.sh that exited 0, and setup.sh has just
  # printed nine numbered next steps in the 'lca' vocabulary. Four more lines
  # here, in the vocabulary of repo script paths, were a second and different
  # answer to the same question, immediately below the first — in the very
  # first thing a new user ever reads. The last of them, "cd <your-project> &&
  # run-agent.sh", also contradicted the handover recipe the assistant is gated
  # to emit ('cd ~/my-project && lca'), so the installer and the chat app
  # taught different commands for the same job.
  say "Done — the numbered next steps are just above, from setup"
}

# Same one-line exit as update.sh, for the same reason: re-running this
# installer against an existing checkout does 'git reset --hard', and if you
# ran it as ${INSTALL_DIR}/install.sh that rewrites the file bash is still
# reading. Piped from curl there is no file to rewrite, but the on-disk case
# is the one people reach for when re-installing.
main "$@"; exit $?
