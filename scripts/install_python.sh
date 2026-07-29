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
  if [[ -x "${venv}/bin/python" ]]; then
    info "Virtualenv already exists at ${venv} — reusing it."
  else
    info "Creating virtualenv at ${venv}..."
    "${PYTHON_BIN}" -m venv "${venv}" \
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
