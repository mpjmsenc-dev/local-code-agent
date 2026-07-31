#!/usr/bin/env bash
# deploy/do-user-data.sh — DigitalOcean first-boot installer (cloud-init).
#
# Paste this WHOLE file into: Create Droplet → Advanced Options →
# "Add Initialization scripts (free)". On the droplet's first boot it clones
# this repository to /opt/local-code-agent and runs the full unattended
# setup, logging everything to /var/log/local-code-agent-setup.log.
#
# Watch progress from the droplet's web console with:
#   tail -f /var/log/local-code-agent-setup.log
#
# It always ends with exactly one of three lines, so watching the log gives a
# definitive answer rather than silence (docs/YOUR-TURN.md step 2 relies on it):
#   SETUP COMPLETE — local-code-agent is ready.
#   SETUP FINISHED WITH ERRORS — ...
#   FIRST-BOOT INSTALL FAILED — ...    (never got as far as running setup)
#
# Safe to re-run (e.g. sudo bash /opt/local-code-agent/deploy/do-user-data.sh).

# ↓↓↓ EDIT ME if you forked the repository ↓↓↓
# (or override without editing the file:
#  sudo LCA_REPO_URL=... LCA_DIR=... bash deploy/do-user-data.sh)
REPO_URL="${LCA_REPO_URL:-https://github.com/mpjmsenc-dev/local-code-agent.git}"
INSTALL_DIR="${LCA_DIR:-/opt/local-code-agent}"
LOG_FILE="${LCA_LOG:-/var/log/local-code-agent-setup.log}"
RUN_SETUP="${LCA_RUN_SETUP:-true}"

set -euo pipefail

# first_boot_failed REASON — the definitive "it did not work" line.
#
# The two steps that realistically fail before setup are apt (no network yet)
# and the clone (wrong or private URL), and both are handled explicitly below
# rather than left to a trap. Explicit beats clever here: 'set -e' is disabled
# inside a function used as an 'if' condition, and an ERR trap is invisible to
# ShellCheck, so both of the tidier-looking options quietly misreport.
first_boot_failed() {
  echo
  echo "FIRST-BOOT INSTALL FAILED — the droplet is NOT ready."
  echo "  $1"
  echo "  Fix the cause, then re-run:  sudo bash ${INSTALL_DIR}/deploy/do-user-data.sh"
}

main() {
  echo "=== local-code-agent first-boot install started: $(date) ==="
  export DEBIAN_FRONTEND=noninteractive
  # cloud-init runs this without a login environment, so $HOME is unset — and
  # the ollama CLI panics ("$HOME is not defined") without it. Set it for root.
  export HOME="${HOME:-/root}"

  echo "--- Installing git (needed to clone the repository) ---"
  # DPkg::Lock::Timeout waits out the apt-daily / unattended-upgrades lock that
  # routinely holds dpkg during the first minutes of a fresh boot — cloud-init
  # runs this exactly once, so failing here would leave a permanently
  # half-installed droplet. (apt on Ubuntu 20.04+/Debian 11+ supports it.)
  if ! apt-get -o DPkg::Lock::Timeout=600 update -y \
    || ! apt-get -o DPkg::Lock::Timeout=600 install -y git ca-certificates curl; then
    first_boot_failed "apt could not install git — this droplet has no working network yet."
    return 1
  fi

  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    echo "--- Repository already cloned, updating it ---"
    git -C "${INSTALL_DIR}" pull --ff-only || echo "(pull failed — continuing with the existing checkout)"
  else
    echo "--- Cloning ${REPO_URL} to ${INSTALL_DIR} ---"
    if ! git clone "${REPO_URL}" "${INSTALL_DIR}"; then
      first_boot_failed "could not clone ${REPO_URL} — check the URL is right and the repository is public."
      return 1
    fi
  fi

  # Git already records these as executable; re-applying is free and covers a
  # clone made under a umask or filesystem that dropped the bit. bin/ matters
  # now too — that is where the 'lca' command lives.
  chmod +x "${INSTALL_DIR}"/*.sh "${INSTALL_DIR}"/scripts/*.sh "${INSTALL_DIR}"/bin/* 2>/dev/null || true

  if [[ "${RUN_SETUP}" != "true" ]]; then
    echo "--- LCA_RUN_SETUP=${RUN_SETUP}: cloned only, setup was NOT run ---"
    echo "=== local-code-agent first-boot install finished: $(date) ==="
    return 0
  fi

  echo "--- Running the unattended setup (this takes ~20-30 minutes) ---"
  # setup.sh prints its own verdict line and exits non-zero on a partial
  # failure. Let that verdict stand rather than adding ours on top: it is more
  # specific, and YOUR-TURN.md teaches the user to look for it.
  # setup.sh prints its own verdict line and exits non-zero on a partial
  # failure. Let that stand rather than stacking a vaguer message on top of a
  # more specific one — YOUR-TURN.md teaches the user to look for setup's line.
  if ! "${INSTALL_DIR}/setup.sh" </dev/null; then
    echo "=== setup reported problems — its verdict line is above: $(date) ==="
    return 1
  fi

  echo "=== local-code-agent first-boot install finished: $(date) ==="
}

# A pipeline rather than 'exec > >(tee ...)': the shell waits for tee to finish,
# so the final verdict line cannot be lost to a race at exit. PIPESTATUS keeps
# the exit status of main rather than tee's.
# A plain pipeline, NOT 'if main | tee': using main as an 'if' condition would
# disable 'set -e' inside it, so a failing clone would sail on and the script
# would report success. Here set -e stays active in main, and pipefail makes
# the pipeline carry main's status rather than tee's.
main 2>&1 | tee -a "${LOG_FILE}"
