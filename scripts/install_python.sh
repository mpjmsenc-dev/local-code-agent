#!/usr/bin/env bash
# scripts/install_python.sh — create the project virtualenv and install
# aider-chat into it. Idempotent: re-running upgrades/repairs the venv.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

# pip_install ARGS... — run venv pip, retrying once (PyPI can be flaky).
#
# '$(venv_python) -m pip', not "${venv}/bin/pip". Two reasons, and the comment
# in main() already states the first: venv_python() is meant to be the one
# place that knows this layout, and building a sibling path by hand is how it
# stops being that. The second is a real failure: a pip wrapper is a script
# whose shebang holds the absolute interpreter path, and Linux truncates a
# shebang at 127 characters — a checkout under a long enough path leaves
# bin/pip with "bad interpreter: No such file or directory" while the
# interpreter itself is perfectly fine. The version check in main() has always
# used the '-m pip' form; only the two lines that actually installed anything
# used the fragile one.
pip_install() {
  local py
  py="$(venv_python)"
  if ! "${py}" -m pip install --upgrade "$@"; then
    warn "pip install $* failed — retrying once in 5 seconds..."
    sleep 5
    "${py}" -m pip install --upgrade "$@"
  fi
}

# venv_target_writable DIR — its own function purely so the two messages below
# can be exercised. As root '[[ -w ]]' is true for every path, so a test that
# runs as root could never reach one of the branches, and a test that depends
# on WHO runs it is the environment dependence this project has been bitten by
# repeatedly.
venv_target_writable() { [[ -w "$1" ]]; }

# venv_create_failed VENV — never returns; dies naming the cause it found.
#
# One message covered both failures: "Could not create a virtualenv. On
# Debian/Ubuntu install it with: sudo apt-get install -y python3-venv".
# Measured as an ordinary user against a checkout owned by root, which is what
# 'sudo setup.sh' leaves behind:
#
#   Error: [Errno 13] Permission denied: '.../.venv'
#   [FAIL] Could not create a virtualenv. On Debian/Ubuntu install it with:
#          sudo apt-get install -y python3-venv
#
# python3-venv is already installed — it got far enough to try — and installing
# it again changes nothing. This is the command scripts/selftest.sh sends
# people to when aider is missing, so it is reached by someone already stuck.
venv_create_failed() {
  local venv="$1" target="$1"
  # The venv itself when it exists (the rebuild path), otherwise its parent —
  # those are different directories and only one of them is the obstacle.
  [[ -e "${target}" ]] || target="$(dirname "${venv}")"
  if ! venv_target_writable "${target}"; then
    die "Cannot create the virtualenv at ${venv} — '${target}' is not writable by '$(id -un)'. A checkout installed with 'sudo setup.sh' is owned by root, so this needs the same: sudo ${REPO_ROOT}/scripts/install_python.sh"
  fi
  die "Could not create a virtualenv at ${venv}, and '${target}' is writable — so the venv module itself is the likely problem. On Debian/Ubuntu install it with: sudo apt-get install -y python3-venv"
}

main() {
  step "Setting up Python virtualenv + aider"
  require_cmd "${PYTHON_BIN}"

  if ! "${PYTHON_BIN}" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'; then
    die "${PYTHON_BIN} is older than 3.10 — aider needs Python >= 3.10. Set PYTHON_BIN in .env to a newer interpreter."
  fi

  local venv
  venv="$(venv_dir)"
  # venv_python(), not "${venv}/bin/python": the helper exists to be the one
  # place that knows the interpreter's path, and building it inline here is how
  # it silently stops being that.
  # The interpreter existing is not the same as a usable venv. An interrupted
  # 'python -m venv', or an ensurepip that failed, leaves bin/python behind
  # with no pip — which passed this check as "already exists", and then every
  # single re-run died on the pip_install below and repaired nothing. The venv
  # could never recover without someone deleting it by hand.
  if [[ -x "$(venv_python)" ]] && "$(venv_python)" -m pip --version >/dev/null 2>&1; then
    info "Virtualenv already exists at ${venv} — reusing it."
  else
    if [[ -x "$(venv_python)" ]]; then
      info "Virtualenv at ${venv} has no working pip (an earlier run was interrupted) — rebuilding it."
    else
      info "Creating virtualenv at ${venv}..."
    fi
    # --clear so a half-built one is replaced rather than reused in place.
    "${PYTHON_BIN}" -m venv --clear "${venv}" || venv_create_failed "${venv}"
  fi

  net_guard "Installing Python packages"
  info "Upgrading pip, wheel and setuptools..."
  pip_install pip wheel setuptools

  local aider_spec="aider-chat"
  if [[ -n "${AIDER_VERSION}" ]]; then
    aider_spec="aider-chat==${AIDER_VERSION}"
    info "Installing pinned ${aider_spec}..."
  else
    info "Installing the latest aider-chat..."
  fi
  pip_install "${aider_spec}"

  local aider
  aider="$(aider_bin)"
  [[ -x "${aider}" ]] || die "aider binary not found at ${aider} after install."
  ok "aider installed: $("${aider}" --version)"
  # bin/lca, not run-agent.sh. This runs before setup.sh has put 'lca' on PATH,
  # so the full path is right — but the WORD has to be the same one setup's
  # next steps and the assistant's handover recipe both use, or the install
  # teaches three names for one command before it has finished.
  info "Run it from any project directory with: ${REPO_ROOT}/bin/lca"
}

# Sourceable so venv_create_failed's two branches can be driven without
# building a virtualenv — the same pattern as scripts/tune.sh and apply.sh.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
