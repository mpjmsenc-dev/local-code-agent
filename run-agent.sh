#!/usr/bin/env bash
# run-agent.sh — start aider (the terminal coding agent) against the local
# Ollama model, from WHATEVER directory you are in. This script never cd's:
# aider must run inside YOUR project directory so it sees your files/git.
#
# Usage: cd ~/my-project && /opt/local-code-agent/run-agent.sh [aider args...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"
load_env

main() {
  local aider
  aider="$(aider_bin)"
  [[ -x "${aider}" ]] || die "aider is not installed at ${aider}. Run: ${REPO_ROOT}/scripts/install_python.sh"
  require_cmd curl jq

  # Make sure Ollama is up (start the service if it is down).
  if ! wait_for_ollama 3; then
    if systemd_available; then
      info "Ollama is not answering — starting the service..."
      as_root systemctl start ollama || true
    fi
    wait_for_ollama 60 || die "Ollama API is not reachable at $(ollama_url). Try: sudo systemctl restart ollama — then check: ${REPO_ROOT}/check-system.sh"
  fi

  if ! model_present "${MODEL_NAME}"; then
    warn "Model '${MODEL_NAME}' is not downloaded yet."
    if confirm "Pull '${MODEL_NAME}' now?"; then
      net_guard "Downloading ${MODEL_NAME}"
      pull_model "${MODEL_NAME}" || die "Could not pull '${MODEL_NAME}'."
    elif [[ "$(netmode_state)" == "offline" ]]; then
      die "Cannot start aider without the model, and netmode is OFFLINE. Run: sudo ${REPO_ROOT}/netmode.sh online — then: ollama pull ${MODEL_NAME}"
    else
      die "Cannot start aider without the model. Pull it with: ollama pull ${MODEL_NAME}"
    fi
  fi

  info "Starting aider with ollama_chat/${MODEL_NAME} in $(pwd)"
  # aider talks to Ollama through litellm, which needs OLLAMA_API_BASE and
  # the ollama_chat/ model prefix.
  export OLLAMA_API_BASE
  OLLAMA_API_BASE="$(ollama_url)"
  exec "${aider}" \
    --config "${REPO_ROOT}/config/aider.conf.yml" \
    --model "ollama_chat/${MODEL_NAME}" \
    "$@"
}

main "$@"
