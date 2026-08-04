#!/usr/bin/env bash
# scripts/install_python.sh — create the project virtualenv and install
# aider-chat into it. Idempotent: re-running upgrades/repairs the venv.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

# pip_install ARGS... — run venv pip, retrying once (PyPI can be flaky).
pip_install() {
  local venv
  venv="$(venv_dir)"
  if ! "${venv}/bin/pip" install --upgrade "$@"; then
    warn "pip install $* failed — retrying once in 5 seconds..."
    sleep 5
    "${venv}/bin/pip" install --upgrade "$@"
  fi
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
    "${PYTHON_BIN}" -m venv --clear "${venv}" \
      || die "Could not create a virtualenv. On Debian/Ubuntu install it with: sudo apt-get install -y python3-venv"
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
  info "Run it from any project directory with: ${REPO_ROOT}/run-agent.sh"
}

main "$@"
