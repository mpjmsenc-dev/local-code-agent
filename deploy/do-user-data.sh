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

  # A clone can succeed and still leave you without the project. install.sh
  # learned this the hard way — "observed here by accident, cloning a stale
  # local 'main' that held only a README" — and this file, whose header opens
  # with an "EDIT ME if you forked the repository" block, never did.
  #
  # Measured against a repository holding one README, everything else stubbed:
  #
  #   .../target/scripts/motd.sh: No such file or directory
  #   (could not install the login banner — continuing)
  #   .../target/setup.sh: No such file or directory
  #   === setup reported problems — its verdict line is above ===
  #
  # ...and NOT ONE of the three lines this file's header promises the log
  # always ends with. It points at a verdict line that does not exist, because
  # setup.sh never ran. docs/YOUR-TURN.md step 2 tells people to watch this log
  # for a definitive answer; a wrong fork or a stale branch is exactly when
  # they need one, and it is exactly when there was none.
  #
  # Checked before the chmod and the banner install below, so their "No such
  # file" noise never happens either.
  if [[ ! -f "${INSTALL_DIR}/setup.sh" ]]; then
    first_boot_failed "cloned ${REPO_URL} but it contains no setup.sh — that is not a local-code-agent checkout. Check the repository URL and the branch it points at."
    return 1
  fi

  # Git already records these as executable; re-applying is free and covers a
  # clone made under a umask or filesystem that dropped the bit. bin/ matters
  # now too — that is where the 'lca' command lives.
  chmod +x "${INSTALL_DIR}"/*.sh "${INSTALL_DIR}"/scripts/*.sh "${INSTALL_DIR}"/bin/* 2>/dev/null || true

  # Install the login banner NOW, before the long part. setup.sh installs it
  # too, but that is 20-30 minutes away — and the entire reason the banner
  # exists is to tell someone who SSHs in during those 20-30 minutes that an
  # install is running. Installed only at the end, it could never report the
  # one state it was written for.
  echo "--- Installing the login banner (so SSH reports install progress) ---"
  "${INSTALL_DIR}/scripts/motd.sh" --install || echo "(could not install the login banner — continuing)"

  if [[ "${RUN_SETUP}" != "true" ]]; then
    echo "--- LCA_RUN_SETUP=${RUN_SETUP}: cloned only, setup was NOT run ---"
    echo "=== local-code-agent first-boot install finished: $(date) ==="
    return 0
  fi

  echo "--- Running the unattended setup (this takes ~20-30 minutes) ---"
  # setup.sh prints its own verdict line and exits non-zero on a partial
  # failure. Let that stand rather than stacking a vaguer message on top of a
  # more specific one — YOUR-TURN.md teaches the user to look for setup's line.
  if ! "${INSTALL_DIR}/setup.sh" </dev/null; then
    echo "=== setup reported problems — its verdict line is above: $(date) ==="
    return 1
  fi

  echo "=== local-code-agent first-boot install finished: $(date) ==="
}

# A pipeline rather than 'exec > >(tee ...)' so the shell waits for tee and the
# final verdict line cannot be lost to a race at exit — and deliberately NOT
# 'if main | tee', because using main as an 'if' condition disables 'set -e'
# inside it, which let a failing clone sail on and report success. Here set -e
# stays active in main and pipefail carries main's status, not tee's.
#
# 'exit $?' on the SAME line, as in install.sh and update.sh. This script is
# documented as safe to re-run from ${INSTALL_DIR}, and re-running it does
# 'git pull --ff-only' on the checkout it is being read from — so an update
# that touches this file replaces it mid-run, and bash then reads whatever now
# sits at its old byte offset. Measured with a stand-in: "SETUP COMPLETE"
# printed, then a fragment of a comment executed and the script exited 127.
# For a file whose stated purpose is to "always end with exactly one of three
# lines", a trailing "command not found" and a false failure status is the
# precise opposite.
main 2>&1 | tee -a "${LOG_FILE}"; exit $?
