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
# Safe to re-run (e.g. sudo bash /opt/local-code-agent/deploy/do-user-data.sh).

# ↓↓↓ EDIT ME if you forked the repository ↓↓↓
REPO_URL="https://github.com/mpjmsenc-dev/local-code-agent.git"

INSTALL_DIR="/opt/local-code-agent"
LOG_FILE="/var/log/local-code-agent-setup.log"

set -euo pipefail
exec > >(tee -a "${LOG_FILE}") 2>&1

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
apt-get -o DPkg::Lock::Timeout=600 update -y
apt-get -o DPkg::Lock::Timeout=600 install -y git ca-certificates curl

if [[ -d "${INSTALL_DIR}/.git" ]]; then
  echo "--- Repository already cloned, updating it ---"
  git -C "${INSTALL_DIR}" pull --ff-only || echo "(pull failed — continuing with the existing checkout)"
else
  echo "--- Cloning ${REPO_URL} to ${INSTALL_DIR} ---"
  git clone "${REPO_URL}" "${INSTALL_DIR}"
fi

chmod +x "${INSTALL_DIR}"/*.sh "${INSTALL_DIR}"/scripts/*.sh

echo "--- Running the unattended setup (this takes ~20-30 minutes) ---"
"${INSTALL_DIR}/setup.sh" </dev/null

echo "=== local-code-agent first-boot install finished: $(date) ==="
